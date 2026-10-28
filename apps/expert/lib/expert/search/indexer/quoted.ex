defmodule Expert.Search.Indexer.Quoted do
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast.Analysis
  alias Forge.ProcessCache
  alias Forge.Project

  require ProcessCache

  def index_with_cleanup(%Analysis{} = analysis) do
    ProcessCache.with_cleanup do
      index(analysis)
    end
  end

  def index_with_cleanup(%Analysis{} = analysis, %Project{} = project, imported_calls) do
    ProcessCache.with_cleanup do
      index(analysis, nil, project, imported_calls)
    end
  end

  def index(analysis, extractors \\ nil), do: do_index(analysis, extractors, nil, nil)

  def index(%Analysis{} = analysis, extractors, project, imported_calls) do
    do_index(analysis, extractors, project, imported_calls)
  end

  defp do_index(%Analysis{valid?: true} = analysis, extractors, nil, _imported_calls) do
    {:ok, extract_entries(analysis, extractors)}
  end

  defp do_index(%Analysis{valid?: true} = analysis, extractors, project, imported_calls) do
    {:ok, extract_entries(analysis, extractors, project, imported_calls)}
  end

  defp do_index(%Analysis{valid?: false}, _extractors, _project, _imported_calls), do: {:ok, []}

  def extract_entries(%Analysis{} = analysis, extractors) do
    do_extract_entries(analysis, Reducer.new(analysis, extractors))
  end

  def extract_entries(%Analysis{} = analysis, extractors, project) do
    do_extract_entries(analysis, Reducer.new(analysis, extractors, project))
  end

  def extract_entries(%Analysis{} = analysis, extractors, project, imported_calls) do
    do_extract_entries(analysis, Reducer.new(analysis, extractors, project, imported_calls))
  end

  defp do_extract_entries(%Analysis{} = analysis, reducer) do
    {_, reducer} =
      Macro.prewalk(analysis.ast, reducer, fn elem, reducer ->
        {reducer, elem} = Reducer.reduce(reducer, elem)
        {elem, reducer}
      end)

    Reducer.entries(reducer)
  end
end
