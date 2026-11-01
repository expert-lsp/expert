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

  def index_with_cleanup(%Analysis{} = analysis, %Project{} = project) do
    ProcessCache.with_cleanup do
      index(analysis, nil, project)
    end
  end

  def index(analysis, extractors \\ nil), do: do_index(analysis, extractors, nil)

  def index(%Analysis{} = analysis, extractors, project) do
    do_index(analysis, extractors, project)
  end

  defp do_index(%Analysis{valid?: true} = analysis, extractors, nil) do
    {:ok, extract_entries(analysis, extractors)}
  end

  defp do_index(%Analysis{valid?: true} = analysis, extractors, project) do
    {:ok, extract_entries(analysis, extractors, project)}
  end

  defp do_index(%Analysis{valid?: false}, _extractors, _project), do: {:ok, []}

  def index_with_structure(%Analysis{valid?: true} = analysis, extractors) do
    reducer = reduce(analysis, Reducer.new(analysis, extractors))
    {:ok, Reducer.block_structure(reducer), Reducer.entries(reducer)}
  end

  def index_with_structure(%Analysis{valid?: false}, _extractors), do: :error

  def extract_entries(%Analysis{} = analysis, extractors) do
    Reducer.entries(reduce(analysis, Reducer.new(analysis, extractors)))
  end

  def extract_entries(
        %Analysis{} = analysis,
        extractors,
        project
      ) do
    Reducer.entries(reduce(analysis, Reducer.new(analysis, extractors, project)))
  end

  defp reduce(%Analysis{} = analysis, reducer) do
    {_, reducer} =
      Macro.prewalk(analysis.ast, reducer, fn elem, reducer ->
        {reducer, elem} = Reducer.reduce(reducer, elem)
        {elem, reducer}
      end)

    reducer
  end
end
