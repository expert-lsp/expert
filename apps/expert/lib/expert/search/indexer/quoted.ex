defmodule Expert.Search.Indexer.Quoted do
  alias Expert.Search.Indexer.Metadata
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.ProcessCache
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Entry
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

  # We reduce only the nodes that span the position, so the entries are the
  # ones whose ranges can contain it.
  def entries_at(%Analysis{valid?: true} = analysis, %Project{} = project, %Position{} = position) do
    ProcessCache.with_cleanup do
      reducer = reduce_at(analysis, Reducer.new(analysis, nil, project), position)
      {:ok, for(entry <- Reducer.entries(reducer), not Entry.is_structure(entry), do: entry)}
    end
  end

  def entries_at(%Analysis{valid?: false}, %Project{}, %Position{}), do: {:ok, []}

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

  defp reduce_at(%Analysis{} = analysis, reducer, %Position{} = position) do
    {_, reducer} =
      Macro.prewalk(analysis.ast, reducer, fn elem, reducer ->
        if spans?(elem, position) do
          {reducer, elem} = Reducer.reduce(reducer, elem)
          {elem, reducer}
        else
          {nil, reducer}
        end
      end)

    reducer
  end

  defp spans?(elem, %Position{} = position) do
    not starts_after?(elem, position) and not ends_before?(elem, position)
  end

  defp starts_after?(elem, position) do
    case start_of(elem) do
      nil -> false
      start -> Position.compare(position, start) == :lt
    end
  end

  defp ends_before?(elem, position) do
    case end_of(elem) do
      nil -> false
      finish -> Position.compare(position, finish) == :gt
    end
  end

  # The first token is the node's own or in its leftmost child.
  defp start_of({form, meta, args}) when is_list(meta) do
    [Metadata.position(meta), start_of(form), start_of(args)]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp start_of({left, _right}), do: start_of(left)
  defp start_of([first | _]), do: start_of(first)
  defp start_of(_), do: nil

  defp end_of({:__aliases__, meta, segments}) when is_list(meta) do
    with {line, column} <- Metadata.position(meta, :last),
         last when is_atom(last) <- List.last(segments) do
      {line, column + String.length(Atom.to_string(last))}
    else
      _ -> nil
    end
  end

  defp end_of({_, meta, _}) when is_list(meta) do
    case {Metadata.position(meta, :end_of_expression), Metadata.position(meta, :end),
          Metadata.position(meta, :closing)} do
      {{_, _} = finish, _, _} -> finish
      {nil, {line, column}, _} -> {line, column + 3}
      {nil, nil, {line, column}} -> {line, column + 1}
      _ -> nil
    end
  end

  defp end_of(_), do: nil
end
