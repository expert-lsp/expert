defmodule Expert.Search.Indexer.Sources do
  alias Expert.Progress
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Source

  require Logger

  def stream(paths, source_indexer \\ &Source.index/2) when is_list(paths) do
    {sized_paths, total_bytes} = stat_paths(paths)

    if sized_paths == [] do
      Stream.concat([])
    else
      sized_paths
      |> Task.async_stream(
        fn {path, size} -> {size, index_path(path, source_indexer)} end,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.transform(
        fn -> start_progress("Indexing source code") end,
        fn task_result, progress ->
          {size, result} = task_result!(task_result)
          {stream_items(result), report_progress(progress, size, total_bytes, "Indexing")}
        end,
        &complete_progress(&1, length(sized_paths))
      )
    end
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

  defp stream_items([]), do: []

  defp stream_items([{[entry | entries], manifest_entry}]) do
    [{entry, [manifest_entry]} | Enum.map(entries, &{&1, []})]
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

  defp task_result!({:ok, result}), do: result

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp start_progress(title) do
    token =
      case Progress.begin(title, percentage: 0) do
        {:ok, token} -> token
        {:error, :rejected} -> nil
      end

    {token, 0, System.monotonic_time(:millisecond)}
  end

  defp report_progress({token, current, start_time}, size, total, message) do
    current = current + size

    if token do
      percentage = if total > 0, do: min(100, div(current * 100, total)), else: 0
      Progress.report(token, message: message, percentage: percentage)
    end

    {token, current, start_time}
  end

  defp complete_progress({token, _current, start_time}, path_count) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("Indexed #{path_count} source files in #{format_duration(elapsed)}")

    if token do
      Progress.complete(token, message: "Completed in #{format_duration(elapsed)}")
    end
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
