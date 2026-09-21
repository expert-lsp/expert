defmodule Expert.Search.Indexer.Extractors.Variable do
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Search.Indexer.Entry

  @defs [:def, :defmacro, :defp, :defmacrop]

  def extract(
        {def, _, [{:when, _, [{_fn_name, _, params} | when_args]}, body]},
        %Reducer{} = reducer
      )
      when def in @defs do
    entries = extract_definitions(params, reducer) ++ extract_references(when_args, reducer)
    {:ok, entries, body}
  end

  def extract({def, _, [{_fn_name, _, params}, body]}, %Reducer{} = reducer)
      when def in @defs do
    entries = extract_definitions(params, reducer)

    {:ok, entries, body}
  end

  # Stab operator  x -> body
  def extract({:->, _, [params, body]}, %Reducer{} = reducer) do
    entries = extract_definitions(params, reducer) ++ extract_in_definitions(params, reducer)

    {:ok, entries, List.wrap(body)}
  end

  # with match operator. with {:ok, var} <- something()
  def extract({:<-, _, [left, right]}, %Reducer{} = reducer) do
    entries = extract_definitions(left, reducer)

    {:ok, entries, List.wrap(right)}
  end

  # Match operator left = right
  def extract({:=, _, [left, right]}, %Reducer{} = reducer) do
    definitions = extract_definitions(left, reducer)

    {:ok, definitions, List.wrap(right)}
  end

  # String interpolations "#{foo}"
  def extract(
        {:<<>>, _, [{:"::", _, [{{:., _, [Kernel, :to_string]}, _, body}, {:binary, _, _}]}]},
        %Reducer{}
      ) do
    {:ok, [], body}
  end

  # Test declarations
  def extract(
        {:test, _metadata,
         [
           {:__block__, [delimiter: "\"", line: 3, column: 8], ["my test"]},
           args,
           body
         ]},
        %Reducer{} = reducer
      ) do
    entries = extract_definitions(args, reducer)
    {:ok, entries, body}
  end

  def extract({:binary, _, _}, %Reducer{}) do
    :ignored
  end

  def extract({:@, _, _}, %Reducer{}) do
    {:ok, nil, nil}
  end

  # Pin operator ^pinned_variable
  def extract({:^, _, [reference]}, %Reducer{} = reducer) do
    reference = extract_reference(reference, reducer, get_current_app(reducer))

    {:ok, reference, nil}
  end

  # Generic variable reference
  def extract({var_name, _, _} = ast, %Reducer{} = reducer) when is_atom(var_name) do
    case extract_reference(ast, reducer, get_current_app(reducer)) do
      %Entry{} = entry -> {:ok, entry}
      _ -> :ignored
    end
  end

  def extract(_ast, _reducer) do
    :ignored
  end

  defp extract_definitions(ast, reducer) do
    current_app = get_current_app(reducer)

    {_ast, entries} =
      Macro.prewalk(ast, [], fn ast, acc ->
        case extract_definition(ast, reducer, current_app) do
          %Entry{} = entry ->
            {ast, [entry | acc]}

          {%Entry{} = entry, ast} ->
            {ast, [entry | acc]}

          {entries, ast} when is_list(entries) ->
            {ast, entries ++ acc}

          {_, ast} ->
            {ast, acc}

          _ ->
            {ast, acc}
        end
      end)

    Enum.reverse(entries)
  end

  # the pin operator is always on the left side of a pattern match, but it's
  # not defining a variable, just referencing one.
  defp extract_definition({:^, _, [reference]}, %Reducer{} = reducer, current_app) do
    reference = extract_reference(reference, reducer, current_app)

    {reference, nil}
  end

  # unquote(expression)
  defp extract_definition({:unquote, _, [expr]}, %Reducer{} = reducer, current_app) do
    reference = extract_reference(expr, reducer, current_app)
    {reference, nil}
  end

  defp extract_definition({:@, _, _}, %Reducer{}, _current_app) do
    {nil, []}
  end

  # when clauses actually contain parameters and references
  defp extract_definition({:when, _, when_args}, %Reducer{} = reducer, _current_app) do
    {definitions, references} =
      Enum.split_with(when_args, fn {_, _, context} -> is_atom(context) end)

    definitions = extract_definitions(definitions, reducer)
    references = extract_references(references, reducer)

    {Enum.reverse(definitions ++ references), nil}
  end

  # This is an effect of string interpolation
  defp extract_definition({:binary, _metadata, nil}, _reducer, _current_app) do
    nil
  end

  defp extract_definition({var_name, _metadata, nil} = ast, reducer, current_app) do
    if used_variable?(var_name) do
      document = reducer.analysis.document
      block = Reducer.current_block(reducer)

      Entry.definition(
        document.path,
        block,
        var_name,
        :variable,
        Ast.Range.fetch!(ast, document),
        current_app
      )
    end
  end

  defp extract_definition(_, _reducer, _current_app), do: nil

  defp extract_references(ast, reducer) do
    current_app = get_current_app(reducer)

    {_ast, entries} =
      Macro.prewalk(ast, [], fn ast, acc ->
        case extract_reference(ast, reducer, current_app) do
          %Entry{} = entry ->
            {ast, [entry | acc]}

          _ ->
            {ast, acc}
        end
      end)

    Enum.reverse(entries)
  end

  defp extract_reference({var_name, _metadata, nil} = ast, reducer, current_app) do
    if used_variable?(var_name) do
      document = reducer.analysis.document
      block = Reducer.current_block(reducer)

      Entry.reference(
        document.path,
        block,
        var_name,
        :variable,
        Ast.Range.fetch!(ast, document),
        current_app
      )
    end
  end

  defp extract_reference(_, _, _) do
    nil
  end

  # extracts definitions like e in SomeException ->
  defp extract_in_definitions(ast, %Reducer{} = reducer) do
    current_app = get_current_app(reducer)

    {_ast, entries} =
      Macro.prewalk(ast, [], fn ast, acc ->
        case extract_in_definition(ast, reducer, current_app) do
          %Entry{} = entry ->
            {ast, [entry | acc]}

          _ ->
            {ast, acc}
        end
      end)

    Enum.reverse(entries)
  end

  defp extract_in_definition(
         [[{:in, _, [definition, _right]}], _body],
         %Reducer{} = reducer,
         current_app
       ) do
    extract_definition(definition, reducer, current_app)
  end

  defp extract_in_definition(_ast, %Reducer{}, _current_app), do: nil

  defp get_current_app(%Reducer{} = reducer) do
    with {:ok, module} <- Analyzer.current_module(reducer.analysis, Reducer.position(reducer)) do
      Engine.ApplicationCache.application(module)
    end
  end

  defp used_variable?(variable_name) do
    not (variable_name
         |> Atom.to_string()
         |> String.starts_with?("_"))
  end
end
