defmodule Expert.Search.Indexer.Sources do
  alias Expert.Progress
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.RawFile
  alias Expert.Search.Indexer.Source

  require Logger

  # 8 MB on a 64-bit VM
  @worker_heap_words 1_000_000

  # A task costs its owner a few message round trips and gets a heap of its
  # own, so each indexes several files.
  @files_per_task 16

  def stream(
        paths,
        source_indexer \\ &Source.index/2,
        encode \\ &Function.identity/1,
        stats \\ %{}
      )
      when is_list(paths) do
    {sized_paths, total_bytes} = stat_paths(paths, stats)

    if sized_paths == [] do
      Stream.concat([])
    else
      sized_paths
      |> Enum.chunk_every(@files_per_task)
      |> Task.async_stream(
        fn group ->
          # A file's syntax tree is many times its size, and a task's heap
          # starts tiny and grows by copying, so without this a third of a
          # worker's time goes to garbage collections that free nothing.
          Process.flag(:min_heap_size, @worker_heap_words)

          Enum.map(group, fn {path, size, stat} ->
            {size, index_path(path, stat, source_indexer, encode)}
          end)
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.transform(
        fn -> start_progress("Indexing source code") end,
        fn task_result, progress ->
          results = task_result!(task_result)
          size = Enum.sum_by(results, fn {size, _result} -> size end)
          items = Enum.flat_map(results, fn {_size, result} -> stream_items(result) end)
          {items, report_progress(progress, size, total_bytes, "Indexing")}
        end,
        &complete_progress(&1, length(sized_paths))
      )
    end
  end

  defp index_path(path, stat, source_indexer, encode) do
    with {:ok, contents} <- RawFile.read(path),
         {:ok, [_ | _] = entries} <- source_indexer.(path, contents),
         true <- has_search_entries?(entries),
         {:ok, manifest_entry} <- manifest_entry(path, stat) do
      [{encode.(entries), manifest_entry}]
    else
      _ -> []
    end
  end

  defp manifest_entry(path, nil), do: Manifest.Entry.source(path)
  defp manifest_entry(path, %File.Stat{} = stat), do: Manifest.Entry.source(path, stat)

  defp has_search_entries?(entries) do
    Enum.any?(entries, fn entry -> entry.subtype != :block_structure end)
  end

  defp stream_items([]), do: []

  defp stream_items([{item, manifest_entry}]), do: [{item, [manifest_entry]}]

  defp stat_paths(paths, stats) do
    sized_paths =
      Enum.map(paths, fn path ->
        case stats do
          %{^path => %File.Stat{size: size} = stat} -> {path, size, stat}
          %{} -> {path, file_size(path), nil}
        end
      end)

    total_bytes = sized_paths |> Enum.map(fn {_path, size, _stat} -> size end) |> Enum.sum()

    {sized_paths, total_bytes}
  end

  defp file_size(path) do
    case RawFile.stat(path) do
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
