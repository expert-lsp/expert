defmodule Expert.Search.Indexer.Source do
  alias Expert.EngineApi
  alias Expert.Search.Indexer
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.State
  alias Forge.Document

  def index(path, source, extractors \\ nil) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors)
  end

  # Only expanding `use` needs the project's code, which is loaded in the
  # engine, so the source is analyzed and indexed here and the engine is asked
  # for what its `use` calls import, if it has any.
  def index(path, source, extractors, project) do
    document = Document.new(path, source, 1)

    case Ast.from(document) do
      {:ok, quoted, _comments} ->
        use_imports =
          if may_call_use?(source),
            do: EngineApi.use_imports(project, quoted, document),
            else: %{}

        {:ok, index_quoted(document, quoted, extractors, project, use_imports)}

      _invalid ->
        {:ok, []}
    end
  end

  def index_document(%Document{} = document, extractors \\ nil) do
    document
    |> Ast.analyze(expand_uses: true)
    |> Indexer.Quoted.index(extractors)
  end

  # True whenever `use` appears as a word followed by its arguments, which
  # covers every `use` call the analysis expands.
  defp may_call_use?(source) do
    source
    |> :binary.matches("use")
    |> Enum.any?(fn {at, _length} ->
      not identifier_byte?(byte_before(source, at)) and
        byte_after(source, at + 3) in [?\s, ?\t, ?\n, ?\r, ?(, ?\\]
    end)
  end

  defp byte_before(_source, 0), do: nil
  defp byte_before(source, at), do: :binary.at(source, at - 1)

  defp byte_after(source, at) when at < byte_size(source), do: :binary.at(source, at)
  defp byte_after(_source, _at), do: nil

  defp identifier_byte?(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9, do: true
  defp identifier_byte?(?_), do: true
  defp identifier_byte?(_byte), do: false

  # Indexes the document in one walk over its AST, carrying the analysis
  # state and the reducer that runs the extractors. The reducer's analysis
  # holds the scopes enclosing the current node, which is all the extractors
  # ask `Analysis.scopes_at/2` about, so the analysis is never built.
  defp index_quoted(document, quoted, extractors, project, use_imports) do
    analysis = %Analysis{ast: quoted, document: document}
    reducer = Reducer.new(analysis, extractors, project)
    {_state, reducer} = walk(quoted, State.new(document, use_imports), reducer)
    Reducer.entries(reducer)
  end

  defp walk(node, state, reducer) when is_tuple(node) or is_list(node) do
    depth = length(state.scopes)
    {node, state} = Analysis.analyze_step(node, state)
    {reducer, node} = reduce(node, state, reducer)

    {state, reducer} =
      Enum.reduce(children(node), {state, reducer}, fn child, {state, reducer} ->
        walk(child, state, reducer)
      end)

    state = if length(state.scopes) > depth, do: State.leave_scope(state), else: state
    {state, reducer}
  end

  defp walk(_leaf, state, reducer), do: {state, reducer}

  defp reduce(
         {_, _, _} = node,
         %State{scopes: scopes},
         %Reducer{analysis: %Analysis{} = analysis} = reducer
       ) do
    reducer = %Reducer{reducer | analysis: %Analysis{analysis | scopes: scopes}}
    Reducer.reduce(reducer, node)
  end

  defp reduce(node, _state, reducer), do: {reducer, node}

  defp children({form, _meta, args}) when is_atom(form) and is_list(args), do: args
  defp children({form, _meta, _args}) when is_atom(form), do: []
  defp children({form, _meta, args}) when is_list(args), do: [form | args]
  defp children({form, _meta, _args}), do: [form]
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_leaf), do: []
end
