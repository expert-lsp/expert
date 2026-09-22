defmodule Expert.Search.Indexer.Sources do
  alias Expert.Progress
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Source

  require Logger

  def index(paths, source_indexer \\ &Source.index/2) when is_list(paths) do
    paths
    |> map_paths("Indexing source code", "Indexing", &index_path(&1, source_indexer))
    |> entries_and_manifest_entries()
  end

  defp index_path(path, source_indexer) do
    with {:ok, contents} <- File.read(path),
         {:ok, [_ | _] = entries} <- source_indexer.(path, contents),
         true <- has_search_entries?(entries),
         {:ok, manifest_entry} <- Manifest.Entry.source(path) do
      [{entries, manifest_entry}]
    else
      _ -> []
    end
  end

  defp has_search_entries?(entries) do
    Enum.any?(entries, fn entry -> entry.subtype != :block_structure end)
  end

  defp entries_and_manifest_entries(results) do
    entries = Enum.flat_map(results, fn {entries, _manifest_entry} -> entries end)
    manifest_entries = Enum.map(results, fn {_entries, manifest_entry} -> manifest_entry end)

    {entries, manifest_entries}
  end

  defp map_paths([], _title, _message, _processor), do: []

  defp map_paths(paths, title, message, processor) do
    {sized_paths, total_bytes} = stat_paths(paths)

    Progress.with_tracked_progress(title, total_bytes, fn report ->
      start_time = System.monotonic_time(:millisecond)

      results =
        sized_paths
        |> Task.async_stream(
          fn {path, size} ->
            result = processor.(path)
            report.(message: message, add: size)
            result
          end,
          timeout: :infinity
        )
        |> Enum.flat_map(&task_result!/1)

      elapsed = System.monotonic_time(:millisecond) - start_time
      Logger.info("Indexed #{length(sized_paths)} source files in #{format_duration(elapsed)}")
      {:done, results, "Completed in #{format_duration(elapsed)}"}
    end)
  end

  defp stat_paths(paths) do
    sized_paths = Enum.map(paths, fn path -> {path, file_size(path)} end)
    total_bytes = sized_paths |> Enum.map(fn {_path, size} -> size end) |> Enum.sum()

    {sized_paths, total_bytes}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp task_result!({:ok, items}), do: items

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
