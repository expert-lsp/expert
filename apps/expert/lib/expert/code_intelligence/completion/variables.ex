defmodule Expert.CodeIntelligence.Completion.Variables do
  @moduledoc """
  Finds variables that are in scope at a document position.
  """

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document.Position

  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]
  @typespecs [:spec, :type, :typep, :opaque, :callback, :macrocallback]
  @scoped [
    :fn,
    :&,
    :quote,
    :for,
    :with,
    :try,
    :receive,
    :cond,
    :match?,
    :defmodule | @definitions
  ]
  @block_keys [:do, :else, :after, :rescue, :catch]

  @doc """
  Returns the names of the variables in scope at `position`, sorted.

  The traversal follows nodes that contain the position and collects bindings
  from prior statements. Invalid documents use the recovered AST.
  """
  @spec in_scope(Analysis.t(), Position.t()) :: [atom()]
  def in_scope(%Analysis{ast: nil}, %Position{}), do: []

  def in_scope(%Analysis{ast: ast} = analysis, %Position{} = position) do
    state = %{
      cursor: {position.line, position.character},
      recovered?: not analysis.valid?,
      in_quote?: false,
      quoted_vars: []
    }

    ast
    |> traverse([], state)
    |> Enum.reject(&special_form?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Parser output represents special forms such as `__MODULE__` as variables.
  defp special_form?(name), do: String.starts_with?(Atom.to_string(name), "__")

  defp traverse({:defmodule, _, [_alias, body]}, vars, state), do: traverse(body, vars, state)

  # A definition starts a new scope. An `unquote` can still access the outer
  # scope when quoted code creates the definition.
  defp traverse({kind, _, [head | body]}, vars, state) when kind in @definitions do
    state = if state.in_quote?, do: state, else: %{state | quoted_vars: vars}

    cond do
      unquote = unquote_holding_cursor(head, state) -> traverse(unquote, vars, state)
      relation(head, state) == :inside -> head_vars(head, state)
      true -> traverse_statements(body, pattern_vars(call_args(head)), state)
    end
  end

  # Quote hygiene exposes only `bind_quoted` variables. An `unquote` restores
  # the scope outside the quote.
  defp traverse({:quote, _, args}, vars, state) when is_list(args) do
    traverse_statements(args, bind_quoted(args), %{state | in_quote?: true, quoted_vars: vars})
  end

  defp traverse({kind, _, args}, _vars, state)
       when kind in [:unquote, :unquote_splicing] and is_list(args) do
    traverse(args, state.quoted_vars, state)
  end

  defp traverse({:@, _, [{attribute, _, _}]}, vars, _state) when attribute in @typespecs, do: vars

  defp traverse({:cond, _, [[{_do, clauses}]]}, vars, state) when is_list(clauses) do
    case last_reached(clauses, state) do
      {:->, _, [conditions, body]} ->
        if relation(conditions, state) == :before do
          bound = Enum.flat_map(conditions, &bound_by/1)
          traverse_statements(statements(body), bound ++ vars, state)
        else
          traverse_statements(conditions, vars, state)
        end

      nil ->
        vars
    end
  end

  # Clause bodies receive every binding from their patterns.
  defp traverse({:->, _, [patterns, body]}, vars, state) do
    if relation(patterns, state) in [:before, :none] do
      bound = pattern_vars(strip_guard(patterns))
      traverse_statements(statements(body), bound ++ vars, state)
    else
      clause_head_vars(patterns, state) ++ vars
    end
  end

  defp traverse({:=, _, [pattern, expr]}, vars, state) do
    if relation(pattern, state) == :inside,
      do: vars_before_cursor(pattern, state) ++ vars,
      else: traverse(expr, vars, state)
  end

  defp traverse({:match?, _, [pattern, expr]}, vars, state) do
    if relation(pattern, state) == :inside,
      do: clause_head_vars([pattern], state) ++ vars,
      else: traverse(expr, vars, state)
  end

  # Generator and match clauses bind variables for later clauses and the `do`
  # block. Other options use the outer scope.
  defp traverse({kind, _, args}, vars, state) when kind in [:for, :with] and is_list(args) do
    {clauses, options} = Enum.split_while(args, &(not keyword_blocks?(&1)))

    case traverse_clauses(clauses, vars, state) do
      {:cursor, vars} -> vars
      {:passed, bound} -> traverse_options(List.flatten(options), bound, vars, state)
    end
  end

  # ExUnit binds the optional test context before it enters the test block.
  defp traverse({:test, _, [_name, pattern, blocks]} = call, vars, state) do
    if keyword_blocks?(blocks),
      do: traverse_with_pattern(pattern, blocks, vars, state),
      else: traverse_call(call, vars, state)
  end

  defp traverse({kind, _, [pattern, blocks]} = call, vars, state)
       when kind in [:setup, :setup_all] do
    if keyword_blocks?(blocks),
      do: traverse_with_pattern(pattern, blocks, vars, state),
      else: traverse_call(call, vars, state)
  end

  defp traverse({_form, _, args} = call, vars, state) when is_list(args),
    do: traverse_call(call, vars, state)

  defp traverse({key, value} = pair, vars, state) do
    if keyword_pair?(pair),
      do: traverse_statements(statements(value), vars, state),
      else: traverse_statements([key, value], vars, state)
  end

  defp traverse(nodes, vars, state) when is_list(nodes),
    do: traverse_statements(nodes, vars, state)

  defp traverse(_node, vars, _state), do: vars

  defp traverse_call({form, _, args}, vars, state) do
    if is_tuple(form) and relation(form, state) == :inside,
      do: traverse(form, vars, state),
      else: traverse_statements(args, vars, state)
  end

  defp traverse_with_pattern(pattern, blocks, vars, state) do
    if relation(pattern, state) == :before,
      do: traverse(blocks, pattern_vars(pattern) ++ vars, state),
      else: vars_before_cursor(pattern, state) ++ vars
  end

  # Prior statements contribute bindings. Only the last started statement can
  # contain the cursor and needs a recursive traversal.
  defp traverse_statements([], vars, _state), do: vars

  defp traverse_statements([node | _] = nodes, vars, state) do
    if clause?(node) or keyword_pair?(node) do
      traverse(last_reached(nodes, state), vars, state)
    else
      started_backwards =
        Enum.reduce_while(nodes, [], fn node, started ->
          case start(node) do
            nil -> {:cont, started}
            from when from < state.cursor -> {:cont, [node | started]}
            _from -> {:halt, started}
          end
        end)

      case started_backwards do
        [last | earlier] ->
          vars = earlier |> Enum.flat_map(&bound_by/1) |> Enum.concat(vars)

          if holds_cursor?(last, state),
            do: traverse(last, vars, state),
            else: bound_by(last) ++ vars

        [] ->
          vars
      end
    end
  end

  # Recovered nodes can end before the cursor even when they contain it.
  defp holds_cursor?(node, state) do
    relation(node, state) == :inside or keyword_blocks?(node) or
      (state.recovered? and unfinished?(node))
  end

  defp unfinished?({:__block__, [{:error, true} | _], _}), do: true
  defp unfinished?({:->, _, [_patterns, nil]}), do: true

  defp unfinished?({_form, meta, [_ | _] = args}) when is_list(meta),
    do: not closed?(meta) and unfinished?(List.last(args))

  defp unfinished?({_key, value}), do: unfinished?(value)
  defp unfinished?([_ | _] = nodes), do: unfinished?(List.last(nodes))
  defp unfinished?(_node), do: false

  # Spitfire omits closing tokens for open calls and functions. For an open
  # block, its recovered `end` position equals its `do` position.
  defp closed?(meta) do
    case {meta[:do], meta[:end]} do
      {nil, _end} -> Keyword.has_key?(meta, :closing)
      {_do, nil} -> false
      {do_position, end_position} -> position(end_position) > position(do_position)
    end
  end

  defp traverse_clauses(clauses, vars, state) do
    Enum.reduce_while(clauses, {:passed, vars}, fn clause, {:passed, bound} ->
      case relation(clause, state) do
        :inside ->
          {:halt, {:cursor, traverse_clause(unwrap_binary_clause(clause), bound, state)}}

        relation when relation in [:before, :none] ->
          {:cont, {:passed, clause_vars(clause) ++ bound}}

        _at_or_after ->
          {:halt, {:cursor, bound}}
      end
    end)
  end

  defp traverse_clause({op, _, [pattern, expr]}, vars, state) when op in [:<-, :=] do
    if relation(pattern, state) == :inside,
      do: vars_before_cursor(pattern, state) ++ vars,
      else: traverse(expr, vars, state)
  end

  defp traverse_clause(filter, vars, state), do: traverse(filter, vars, state)

  defp clause_vars(clause) do
    case unwrap_binary_clause(clause) do
      {op, _, [pattern, _expr]} when op in [:<-, :=] -> pattern_vars(strip_guard([pattern]))
      _filter -> []
    end
  end

  defp unwrap_binary_clause({:<<>>, _, [{:<-, _, _} = clause]}), do: clause
  defp unwrap_binary_clause(clause), do: clause

  defp traverse_options(options, bound, outer, state) do
    case last_reached(options, state) do
      {key, _value} = option ->
        if literal(key) == :do,
          do: traverse(option, bound, state),
          else: traverse(option, outer, state)

      nil ->
        bound
    end
  end

  # A repeated variable in a pattern refers to its earlier binding. A guard
  # receives all bindings from the head.
  defp head_vars({:when, _, [call | _guards]}, state) do
    if relation(call, state) == :inside,
      do: head_vars(call, state),
      else: pattern_vars(call_args(call))
  end

  defp head_vars({_name, _, params}, state) when is_list(params),
    do: vars_before_cursor(params, state)

  defp head_vars(_head, _state), do: []

  defp clause_head_vars([{:when, _, args}], state) do
    {patterns, guards} = Enum.split(args, -1)

    if relation(guards, state) == :inside or relation(patterns, state) == :before,
      do: pattern_vars(patterns),
      else: vars_before_cursor(patterns, state)
  end

  defp clause_head_vars(patterns, state), do: vars_before_cursor(patterns, state)

  defp unquote_holding_cursor(head, state) do
    {_head, unquote} =
      Macro.prewalk(head, nil, fn
        {kind, _, args} = node, nil
        when kind in [:unquote, :unquote_splicing] and is_list(args) ->
          {node, if(relation(node, state) == :inside, do: node)}

        node, found ->
          {node, found}
      end)

    unquote
  end

  # Matches contribute bindings only along expressions that always run in the
  # current scope.
  defp bound_by({:=, _, [pattern, expr]}), do: pattern_vars(pattern) ++ bound_by(expr)

  defp bound_by({kind, _, [subject | _]}) when kind in [:if, :unless, :case],
    do: bound_by(subject)

  defp bound_by({operator, _, [left, _right]}) when operator in [:&&, :||, :and, :or],
    do: bound_by(left)

  defp bound_by({kind, _, _}) when kind in @scoped, do: []

  defp bound_by({_form, _, args}) when is_list(args), do: bound_by(args)

  defp bound_by(nodes) when is_list(nodes) do
    nodes
    |> Enum.reject(&do_blocks?/1)
    |> Enum.flat_map(&bound_by/1)
  end

  defp bound_by({_key, value}), do: bound_by(value)
  defp bound_by(_node), do: []

  defp bind_quoted(args) do
    for options <- args,
        keyword_blocks?(options),
        {key, value} <- options,
        literal(key) == :bind_quoted,
        {name, _value} <- List.wrap(literal(value)),
        do: literal(name)
  end

  defp call_args({:when, _, [call | _guards]}), do: call_args(call)
  defp call_args({_name, _, args}) when is_list(args), do: args
  defp call_args(_call), do: []

  defp strip_guard([{:when, _, args}]), do: Enum.drop(args, -1)
  defp strip_guard(patterns), do: patterns

  defp pattern_vars(pattern) do
    pattern |> pattern_var_nodes() |> Enum.map(&elem(&1, 0))
  end

  # A partial variable at the cursor is not a prior binding.
  defp vars_before_cursor(pattern, state) do
    for {name, _meta, _context} = var <- pattern_var_nodes(pattern),
        relation(var, state) == :before,
        do: name
  end

  defp pattern_var_nodes(pattern) do
    {_pattern, vars} =
      Ast.prewalk_vars(pattern, [], fn
        {:^, _, _} = pinned, vars -> {pinned, vars}
        var, vars -> {var, [var | vars]}
      end)

    vars
  end

  defp statements({:__block__, _, [_, _ | _] = statements}), do: statements
  defp statements(clauses) when is_list(clauses), do: clauses
  defp statements(body), do: [body]

  # Include a clause or keyword pair when the cursor is at its first character.
  defp last_reached(nodes, state) do
    nodes
    |> Enum.filter(&(start(&1) != nil and start(&1) <= state.cursor))
    |> List.last()
  end

  defp clause?(node), do: match?({:->, _, [_, _]}, node)

  defp keyword_pair?({key, _value}), do: is_atom(literal(key))
  defp keyword_pair?(_node), do: false

  defp keyword_blocks?([_ | _] = nodes), do: Enum.all?(nodes, &keyword_pair?/1)
  defp keyword_blocks?(_node), do: false

  defp do_blocks?(nodes) do
    keyword_blocks?(nodes) and
      Enum.all?(nodes, fn {key, _value} -> literal(key) in @block_keys end)
  end

  # Forge's literal encoder wraps keyword keys in `__block__` nodes.
  defp literal({:__block__, _, [value]}), do: value
  defp literal(value), do: value

  defp relation(node, state) do
    case start(node) do
      nil -> :none
      from when from > state.cursor -> :after
      from when from == state.cursor -> :at_start
      _from -> if finish(node, state.recovered?) >= state.cursor, do: :inside, else: :before
    end
  end

  # Operators can start at their left operand, before their own metadata.
  defp start({:__block__, _, []}), do: nil

  defp start({form, meta, args}) when is_list(meta) do
    [
      position(meta),
      position(meta[:parens] || []),
      if(is_tuple(form), do: start(form)),
      start(args)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp start({key, value}), do: start(key) || start(value)
  defp start(nodes) when is_list(nodes), do: Enum.find_value(nodes, &start/1)
  defp start(_node), do: nil

  # A recovered AST uses token metadata because Sourceror cannot range error
  # nodes. Child ranges can extend beyond the parent metadata.
  defp finish({:__block__, _, []}, _recovered?), do: {0, 0}

  defp finish({_form, meta, args} = node, recovered?) when is_list(meta) do
    own = if recovered?, do: closing_end(node), else: sourceror_end(node)

    [own, position(meta[:end_of_expression] || []), finish(args, recovered?)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max()
  end

  defp finish({key, value}, recovered?),
    do: max(finish(key, recovered?), finish(value, recovered?))

  defp finish([_ | _] = nodes, recovered?), do: nodes |> List.last() |> finish(recovered?)
  defp finish(_node, _recovered?), do: {0, 0}

  defp sourceror_end(node) do
    case Sourceror.get_range(node) do
      %{end: to} -> position(to)
      nil -> nil
    end
  end

  defp closing_end({name, meta, context}) when is_atom(name) and is_atom(context),
    do: shift(meta, name_length(name))

  defp closing_end({:__block__, _, [literal]} = node) when not is_list(literal),
    do: sourceror_end(node)

  defp closing_end({:__aliases__, meta, segments}) when is_list(segments),
    do: shift(meta[:last] || [], segments |> List.last() |> name_length())

  defp closing_end({{:., _, [_left, name]}, meta, []}) when is_atom(name),
    do: shift(meta, name_length(name))

  # Delimited literals lack closing token metadata, so Sourceror supplies their
  # ranges unless recovery nodes prevent it.
  defp closing_end({form, meta, _args} = node) do
    cond do
      meta[:delimiter] && not recovery_node?(node) -> sourceror_end(node)
      meta[:end] -> shift(meta[:end], 3)
      meta[:closing] -> shift(meta[:closing], closing_width(form))
      meta[:parens][:closing] -> shift(meta[:parens][:closing], 1)
      true -> nil
    end
  end

  defp closing_width(:fn), do: 3
  defp closing_width(:<<>>), do: 2
  defp closing_width(_form), do: 1

  defp recovery_node?(node) do
    {_node, found?} =
      Macro.prewalk(node, false, fn
        {:__block__, _, []} = empty, _found? -> {empty, true}
        {:__block__, [{:error, true} | _], _} = error, _found? -> {error, true}
        other, found? -> {other, found?}
      end)

    found?
  end

  defp name_length(name) when is_atom(name), do: name |> Atom.to_charlist() |> length()
  defp name_length(_name), do: 0

  defp shift(keyword, columns) do
    case position(keyword) do
      {line, column} -> {line, column + columns}
      nil -> nil
    end
  end

  defp position(keyword) do
    if keyword[:line], do: {keyword[:line], keyword[:column]}
  end
end
