defmodule Engine.Search.Indexer.Quoted do
  alias Engine.Search.Indexer.Source.Reducer
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.ProcessCache
  alias Forge.Search.Indexer.Entry

  require ProcessCache

  def index_with_cleanup(%Analysis{} = analysis) do
    ProcessCache.with_cleanup do
      index(analysis)
    end
  end

  def index(analysis, extractors \\ nil)

  def index(%Analysis{valid?: true} = analysis, extractors) do
    {:ok, extract_entries(analysis, extractors)}
  end

  def index(%Analysis{valid?: false}, _extractors) do
    {:ok, []}
  end

  def extract_entries(%Analysis{} = analysis, extractors) do
    {_, reducer} =
      Macro.prewalk(analysis.ast, Reducer.new(analysis, extractors), fn elem, reducer ->
        {reducer, elem} = Reducer.reduce(reducer, elem)
        {elem, reducer}
      end)

    main_entries = Reducer.entries(reducer)
    expansion_entries = extract_expansion_entries(analysis, extractors)

    main_entries ++ expansion_entries
  end

  defp extract_expansion_entries(%Analysis{expansions: []} = _analysis, _extractors), do: []

  defp extract_expansion_entries(%Analysis{expansions: expansions} = analysis, extractors) do
    Enum.flat_map(expansions, fn {sourceror_range, expanded_ast, _env, _scope_id} ->
      macro_range = sourceror_range_to_forge_range(sourceror_range, analysis.document)

      {_, reducer} =
        Macro.prewalk(expanded_ast, Reducer.new(analysis, extractors), fn elem, reducer ->
          elem = maybe_skip_original_source_node(elem, sourceror_range)
          {reducer, elem} = Reducer.reduce(reducer, elem)
          {elem, reducer}
        end)

      reducer.entries
      |> Enum.reverse()
      |> Enum.map(fn %Entry{} = entry -> %{entry | range: macro_range} end)
    end)
  end

  # Marks an AST node as skipped if its position falls within the expansion's
  # source range, meaning it was already present in the original source and
  # will be indexed by the main AST walk.
  defp maybe_skip_original_source_node({form, meta, args} = elem, sourceror_range)
       when is_list(meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if line && column && position_in_sourceror_range?({line, column}, sourceror_range) do
      {form, Reducer.skip(meta), args}
    else
      elem
    end
  end

  defp maybe_skip_original_source_node(elem, _sourceror_range), do: elem

  defp position_in_sourceror_range?({line, col}, %{start: start_pos, end: end_pos}) do
    [line: start_line, column: start_col] = start_pos
    [line: end_line, column: end_col] = end_pos

    cond do
      line > start_line and line < end_line -> true
      line == start_line and line == end_line -> col >= start_col and col <= end_col
      line == start_line -> col >= start_col
      line == end_line -> col <= end_col
      true -> false
    end
  end

  defp sourceror_range_to_forge_range(%{start: start_pos, end: end_pos}, document) do
    [line: start_line, column: start_column] = start_pos
    [line: end_line, column: end_column] = end_pos

    Range.new(
      Position.new(document, start_line, start_column),
      Position.new(document, end_line, end_column)
    )
  end
end
