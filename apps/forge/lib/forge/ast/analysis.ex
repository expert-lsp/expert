defmodule Forge.Ast.Analysis do
  @moduledoc """
  A data structure representing an analyzed AST.

  See `Forge.Ast.analyze/1`.
  """

  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Require
  alias Forge.Ast.Analysis.Scope
  alias Forge.Ast.Analysis.State
  alias Forge.Ast.Analysis.Use
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Identifier
  alias Sourceror.Zipper

  defstruct [:ast, :document, :parse_error, scopes: [], comments_by_line: %{}, valid?: true]

  @type t :: %__MODULE__{}
  @scope_id :_scope_id

  @block_keywords [:do, :else, :rescue, :catch, :after]
  @clauses [:->]
  @use_expansion_timeout 5_000

  @doc false
  def new(parse_result, document, opts \\ [])

  def new({:ok, ast}, %Document{} = document, opts) do
    new({:ok, ast, []}, document, opts)
  end

  def new({:ok, ast, comments}, %Document{} = document, opts) do
    use_imports = expand_use_imports(ast, document, opts)
    scopes = traverse(ast, document, use_imports)
    comments_by_line = Map.new(comments, fn comment -> {comment.line, comment} end)

    %__MODULE__{
      ast: ast,
      document: document,
      scopes: scopes,
      comments_by_line: comments_by_line
    }
  end

  def new({:error, ast, parse_error, comments}, %Document{} = document, _opts) do
    scopes = traverse(ast, document, %{})
    comments_by_line = Map.new(comments, fn comment -> {comment.line, comment} end)

    %__MODULE__{
      ast: ast,
      document: document,
      scopes: scopes,
      comments_by_line: comments_by_line,
      parse_error: {:error, parse_error, comments},
      valid?: false
    }
  end

  def new(error, document, _opts) do
    %__MODULE__{
      document: document,
      parse_error: error,
      valid?: false
    }
  end

  @doc """
  Returns the scopes for the given position, sorted by nearest proximity.
  """
  def scopes_at(%__MODULE__{scopes: scopes}, %Position{} = position) do
    scopes
    |> Enum.filter(fn %Scope{range: range} = scope ->
      scope.id == :global or Range.contains?(range, position)
    end)
    |> Enum.sort_by(
      fn
        %Scope{id: :global} -> 0
        %Scope{range: range} -> {range.start.line, range.start.character}
      end,
      :desc
    )
  end

  @doc false
  def scope_id({_, meta, _}) when is_list(meta) do
    Keyword.get(meta, @scope_id)
  end

  def scope_id({left, right}) do
    {scope_id(left), scope_id(right)}
  end

  def scope_id(list) when is_list(list) do
    Enum.map(list, &scope_id/1)
  end

  def scope_id(_) do
    nil
  end

  def commented?(%__MODULE__{} = analysis, %Position{} = position) do
    case Map.fetch(analysis.comments_by_line, position.line) do
      {:ok, comment} -> position.character > comment[:column]
      _ -> false
    end
  end

  @doc """
  Returns the scope of the nearest enclosing module of the given function.

  If there is no enclosing module scope, the global scope is returned
  """
  @spec module_scope(t(), Range.t()) :: Scope.t()
  def module_scope(%__MODULE__{} = analysis, %Range{} = range) do
    enclosing_scopes =
      analysis
      |> scopes_at(range.start)
      |> enclosing_scopes(range)

    first_scope = List.first(enclosing_scopes)

    Enum.reduce_while(enclosing_scopes, first_scope, fn
      %Scope{module: same} = current, %Scope{module: same} ->
        {:cont, current}

      _, current ->
        {:halt, current}
    end)
  end

  defp enclosing_scopes(scopes, range) do
    Enum.filter(scopes, fn scope ->
      Range.contains?(scope.range, range.start)
    end)
  end

  defp traverse(quoted, %Document{} = document, use_imports) do
    quoted = preprocess(quoted)

    {_, state} =
      Macro.traverse(
        quoted,
        State.new(document, use_imports),
        fn quoted, state ->
          case analyze_node(quoted, state) do
            {new_quoted, new_state} ->
              {new_quoted, new_state}

            new_state ->
              {quoted, new_state}
          end
        end,
        fn quoted, state ->
          case {scope_id(quoted), State.current_scope(state)} do
            {id, %Scope{id: id}} ->
              {quoted, State.pop_scope(state)}

            _ ->
              {quoted, state}
          end
        end
      )

    if length(state.scopes) != 1 do
      raise RuntimeError,
            "invariant not met, :scopes should only contain the global scope: #{inspect(state)}"
    end

    state
    # pop the final, global state
    |> State.pop_scope()
    |> Map.fetch!(:visited)
    |> Map.reject(fn {_id, scope} -> Scope.empty?(scope) end)
    |> correct_ranges(quoted, document)
    |> Map.values()
  end

  defp preprocess(quoted) do
    Macro.prewalk(quoted, &with_scope_id/1)
  end

  defp expand_use_imports(ast, document, opts) do
    if Keyword.get(opts, :expand_uses, false) do
      do_expand_use_imports(ast, document.path)
    else
      %{}
    end
  end

  defp do_expand_use_imports(ast, path) do
    case instrument_uses(ast) do
      {_instrumented, 0} ->
        %{}

      {instrumented, _count} ->
        instrumented
        |> expand_cursor_envs(path)
        |> imports_from_cursor_envs()
    end
  end

  defp imports_from_cursor_envs({:ok, cursor_envs}) do
    Map.new(cursor_envs, fn {id, cursor_env} ->
      {id, imported_mfas(cursor_env)}
    end)
  end

  defp imports_from_cursor_envs({:error, _reason}), do: %{}

  defp expand_cursor_envs(ast, path) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Spitfire.Env.expand_with_cursor_envs(ast, path, Future.Macro.Env)
        end)

      case Task.yield(task, @use_expansion_timeout) do
        {:ok, {_, _, _, cursor_envs}} ->
          {:ok, cursor_envs}

        {:exit, reason} ->
          {:error, reason}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp instrument_uses(ast) do
    Macro.postwalk(ast, 0, fn
      {:use, meta, [{:__aliases__, _, _} | _]} = use, count ->
        case use_id(meta) do
          {line, column} = id when is_integer(line) and is_integer(column) ->
            cursor = {:__cursor__, [cursor_id: id], []}
            {{:__block__, [], [use, cursor]}, count + 1}

          _ ->
            {use, count}
        end

      node, count ->
        {node, count}
    end)
  end

  defp imported_mfas(%{module: current_module, functions: functions, macros: macros}) do
    for {module, functions} <- functions ++ macros,
        module != current_module,
        {function, arity} <- functions,
        uniq: true do
      {module, function, arity}
    end
  end

  defp use_id(meta), do: {Keyword.get(meta, :line), Keyword.get(meta, :column)}

  defp correct_ranges(scopes, quoted, document) do
    {_zipper, scopes} =
      quoted
      |> Zipper.zip()
      |> Zipper.traverse(scopes, fn %Zipper{node: node} = zipper, scopes ->
        id = scope_id(node)

        if scope = scopes[id] do
          {zipper, Map.put(scopes, id, maybe_correct_range(scope, zipper, document))}
        else
          {zipper, scopes}
        end
      end)

    scopes
  end

  # extend range for block pairs to either the beginning of their next
  # sibling or, if they are the last element, the end of their parent
  defp maybe_correct_range(scope, %Zipper{node: {_, _}} = zipper, %Document{} = document) do
    with %Zipper{node: sibling} <- Zipper.right(zipper),
         %{start: sibling_start} <- Sourceror.get_range(sibling) do
      new_end = Position.new(document, sibling_start[:line], sibling_start[:column])
      put_in(scope.range.end, new_end)
    else
      _ ->
        # we go up twice to get to the real parent because ast pairs
        # are always in a list
        %Zipper{node: parent} = zipper |> Zipper.up() |> Zipper.up()

        case Sourceror.get_range(parent) do
          %{end: parent_end} ->
            new_end = Position.new(document, parent_end[:line], parent_end[:column])
            put_in(scope.range.end, new_end)

          _ ->
            scope
        end
    end
  end

  defp maybe_correct_range(scope, _zipper, _document) do
    scope
  end

  # add a unique ID to 3-element tuples
  defp with_scope_id({_, _, _} = quoted) do
    id = Identifier.next_global!()
    Macro.update_meta(quoted, &Keyword.put(&1, @scope_id, id))
  end

  defp with_scope_id(quoted) do
    quoted
  end

  @skip :skipped?

  defp skip_leading_do({_, meta, _} = root_ast) do
    # Marks the first do block after the passed in node. This is because
    # that do block doesn't have accurate ending information, and if we build
    # a scope around it, it won't end properly, which will cause information
    # contained in scopes to leak out of them.

    case Keyword.fetch(meta, :do) do
      {:ok, [line: line, column: column]} ->
        Macro.prewalk(root_ast, fn
          {:__block__, _meta, [:do]} = block_ast ->
            case Sourceror.get_start_position(block_ast) do
              [line: ^line, column: ^column] ->
                skip(block_ast)

              _ ->
                block_ast
            end

          other ->
            other
        end)

      _ ->
        root_ast
    end
  end

  defp skip({_, _, _} = quoted) do
    Macro.update_meta(quoted, &Keyword.put(&1, @skip, true))
  end

  defp skipped?({_, meta, _}) when is_list(meta) do
    skipped?(meta)
  end

  defp skipped?(meta) when is_list(meta) do
    Keyword.get(meta, @skip, false)
  end

  defp skipped?(_), do: false

  @module_defining_forms [:defmodule, :defprotocol]
  # defmodule Foo do or defprotocol MyProtocol do
  defp analyze_node({form, _meta, [{:__aliases__, _, segments} | _]} = quoted, state)
       when form in @module_defining_forms do
    module =
      case State.current_module(state) do
        [] -> segments
        current_module -> reify_alias(current_module, segments)
      end

    current_module_alias = Alias.implicit(state.document, quoted, module, :__MODULE__)

    new_state =
      state
      # implicit alias belongs to the current scope
      |> maybe_push_implicit_alias(segments, state.document, quoted)
      # new __MODULE__ alias belongs to the new scope
      |> State.push_scope_for(quoted, module)
      |> State.push_alias(current_module_alias)

    {skip_leading_do(quoted), new_state}
  end

  # defimpl Foo, for: SomeProtocol do
  defp analyze_node(
         {:defimpl, _meta,
          [
            {:__aliases__, _, protocol_segments},
            [{_for_keyword, {:__aliases__, _, for_segments}}] | _
          ]} = quoted,
         state
       ) do
    expanded_for = expand_alias(for_segments, state)
    module = expand_alias(protocol_segments ++ expanded_for, state)
    current_module_alias = Alias.implicit(state.document, quoted, module, :__MODULE__)
    for_alias = Alias.implicit(state.document, quoted, expanded_for, :"@for")
    protocol_alias = Alias.implicit(state.document, quoted, protocol_segments, :"@protocol")

    new_state =
      state
      |> State.push_scope_for(quoted, module)
      |> State.push_alias(current_module_alias)
      |> State.push_alias(for_alias)
      |> State.push_alias(protocol_alias)

    {skip_leading_do(quoted), new_state}
  end

  # alias Foo.{Bar, Baz, Buzz.Qux}
  defp analyze_node(
         {:alias, _meta, [{{:., _, [aliases, :{}]}, _, aliases_nodes}]} = quoted,
         state
       ) do
    base_segments = expand_alias(aliases, state)

    Enum.reduce(aliases_nodes, state, fn
      {:__aliases__, _, segments}, state ->
        alias =
          Alias.explicit(state.document, quoted, base_segments ++ segments, List.last(segments))

        State.push_alias(state, alias)

      # Syntactically incorrect code might result in something different than a tuple with :__aliases__
      # as the first element. For example:
      #
      # alias Foo.{Bar
      # results in :__cursor__ as the first element
      #
      # alias Foo.{Bar,
      # results in :__block__
      #
      # In such case we just skip the node.
      {type, _, _}, state when type in [:__cursor__, :__block__] ->
        state
    end)
  end

  # alias Foo
  # alias Foo.Bar
  # alias __MODULE__.Foo
  defp analyze_node({:alias, _meta, [aliases]} = quoted, state) do
    case expand_alias(aliases, state) do
      [_ | _] = segments ->
        alias = Alias.explicit(state.document, quoted, segments, List.last(segments))
        State.push_alias(state, alias)

      [] ->
        state
    end
  end

  # alias Foo, as: Bar
  defp analyze_node({:alias, meta, [aliases, options]} = quoted, state) do
    with {:ok, alias_as} <- fetch_alias_as(options),
         [_ | _] = segments <- expand_alias(aliases, state) do
      alias = Alias.explicit(state.document, quoted, segments, alias_as)
      State.push_alias(state, alias)
    else
      _ ->
        analyze_node({:alias, meta, [aliases]}, state)
    end
  end

  # import with selector import MyModule, only: :functions
  defp analyze_node(
         {:import, _meta, [{:__aliases__, _aliases, module}, selector]} = quoted,
         state
       ) do
    State.push_import(state, Import.new(state.document, quoted, module, selector))
  end

  # wholesale import import MyModule
  defp analyze_node({:import, _meta, [{:__aliases__, _aliases, module}]} = quoted, state) do
    State.push_import(state, Import.new(state.document, quoted, module))
  end

  # require MyModule, as: Alias
  defp analyze_node({:require, _meta, [{:__aliases__, _, module}, options]} = quoted, state) do
    case fetch_alias_as(options) do
      {:ok, as_module} ->
        State.push_require(state, Require.new(state.document, quoted, module, as_module))

      :error ->
        state
    end
  end

  # require MyModule
  defp analyze_node(
         {:require, _meta, [{:__aliases__, _, module}]} = quoted,
         state
       ) do
    State.push_require(state, Require.new(state.document, quoted, module))
  end

  # use MyModule
  defp analyze_node(
         {:use, meta, [{:__aliases__, _, module} | opts]} = use,
         state
       ) do
    imported_mfas = Map.get(state.use_imports, use_id(meta))
    State.push_use(state, Use.new(state.document, use, module, opts, imported_mfas))
  end

  # stab clauses: ->
  defp analyze_node({clause, _, _} = quoted, state) when clause in @clauses do
    maybe_push_scope_for(state, quoted)
  end

  # blocks: do, else, etc.
  defp analyze_node({{:__block__, meta, [block]}, _} = quoted, state)
       when block in @block_keywords do
    if skipped?(meta) do
      state
    else
      maybe_push_scope_for(state, quoted)
    end
  end

  # catch-all
  defp analyze_node(_quoted, state) do
    state
  end

  defp maybe_push_implicit_alias(
         %State{} = state,
         [first_segment | _] = module_segments,
         document,
         quoted
       )
       when is_atom(first_segment) do
    segments =
      case State.current_module(state) do
        # the head element of top-level modules can be aliased, so we
        # must expand them
        [] ->
          expand_alias(module_segments, state)

        # if we have a current module, we prefix the segments with it
        current_module ->
          current_module ++ module_segments
      end

    implicit_alias =
      Alias.implicit(
        document,
        quoted,
        segments,
        module_segments
      )

    State.push_alias(state, implicit_alias)
  end

  # don't create an implicit alias if the module is defined using complex forms:
  # defmodule __MODULE__.Foo do
  # defmodule unquote(...) do
  defp maybe_push_implicit_alias(%State{} = state, [non_atom | _], _, _)
       when not is_atom(non_atom) do
    state
  end

  defp expand_alias({:__MODULE__, _, nil}, state) do
    State.current_module(state)
  end

  defp expand_alias({:__aliases__, _, segments}, state) do
    expand_alias(segments, state)
  end

  defp expand_alias([{:__MODULE__, _, nil} | segments], state) do
    State.current_module(state) ++ segments
  end

  defp expand_alias([first | rest], state) do
    alias_map = state |> State.current_scope() |> Scope.alias_map()

    case alias_map do
      %{[^first] => existing_alias} ->
        existing_alias.module ++ rest

      _ ->
        [first | rest]
    end
  end

  defp expand_alias(quoted, state) do
    reify_alias(State.current_module(state), List.wrap(quoted))
  end

  # Expands aliases given the rules in the special form
  # https://hexdocs.pm/elixir/1.13.4/Kernel.SpecialForms.html#__aliases__/1

  # When the head element is the atom :"Elixir", no expansion happens
  defp reify_alias(_, [:"Elixir" | _] = reified) do
    reified
  end

  # Without a current module, we can't expand a non-atom head element
  defp reify_alias([], [non_atom | rest]) when not is_atom(non_atom) do
    rest
  end

  # With no current module and an atom head, no expansion occurs
  defp reify_alias([], [atom | _] = reified) when is_atom(atom) do
    reified
  end

  # Expand current module
  defp reify_alias(current_module, [{:__MODULE__, _, nil} | rest]) do
    current_module ++ rest
  end

  # With a current module and an atom head, the alias is nested in the
  # current module
  defp reify_alias(current_module, [atom | _rest] = reified) when is_atom(atom) do
    current_module ++ reified
  end

  # In other cases, attempt to expand the unreified head element
  defp reify_alias(current_module, [unreified | rest]) do
    module = Module.concat(current_module)
    env = %Macro.Env{module: module}
    reified = Macro.expand(unreified, env)

    if is_atom(reified) do
      reified_segments = reified |> Module.split() |> Enum.map(&String.to_atom/1)
      reified_segments ++ rest
    else
      rest
    end
  end

  defp fetch_alias_as(options) when is_list(options) do
    alias_as =
      Enum.find_value(options, fn
        {{:__block__, _, [:as]}, {:__aliases__, _, [alias_as]}} -> alias_as
        _ -> nil
      end)

    case alias_as do
      nil -> :error
      _ -> {:ok, alias_as}
    end
  end

  # When the `as` section is incomplete, like: `alias Foo, a`
  defp fetch_alias_as(_) do
    :error
  end

  defp maybe_push_scope_for(%State{} = state, ast) do
    if skipped?(ast) do
      state
    else
      State.maybe_push_scope_for(state, ast)
    end
  end
end
