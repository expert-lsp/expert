defmodule Expert.Search.Indexer.Sources do
  alias Expert.Progress
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Source
  alias Expert.Search.Indexer.Sources.Worker

  require Logger

  def stream(paths, source_indexer \\ &Source.index/2, encode \\ &Function.identity/1)

  def stream([], _source_indexer, _encode), do: Stream.concat([])

  def stream(paths, source_indexer, encode) when is_list(paths) do
    total = length(paths)

    paths
    |> index_stages(&index_path(&1, source_indexer, encode))
    |> Stream.transform(
      fn -> start_progress("Indexing source code") end,
      fn result, progress -> {result, report_progress(progress, 1, total, "Indexing")} end,
      &complete_progress(&1, total)
    )
  end

  # With demand forwarded any earlier, a small project's producer is drained and
  # gone before the last workers subscribe to it.
  defp index_stages(paths, index) do
    {:ok, producer} =
      GenStage.from_enumerable(paths, demand: :accumulate, on_cancel: :stop)

    workers =
      for _ <- 1..System.schedulers_online() do
        {:ok, worker} = Worker.start_link(producer, index)

        {:ok, _subscription} =
          GenStage.sync_subscribe(worker,
            to: producer,
            max_demand: 10,
            min_demand: 5,
            cancel: :transient
          )

        {worker, max_demand: 200, cancel: :temporary}
      end

    GenStage.demand(producer, :forward)
    GenStage.stream(workers)
  end

  defp index_path(path, source_indexer, encode) do
    with {:ok, contents} <- Expert.File.read(path),
         {:ok, [_ | _] = entries} <- source_indexer.(path, contents),
         true <- has_search_entries?(entries),
         {:ok, manifest_entry} <- Manifest.Entry.source(path) do
      [{encode.(entries), [manifest_entry]}]
    else
      _ -> []
    end
  end

  defp has_search_entries?(entries) do
    Enum.any?(entries, fn entry -> entry.subtype != :block_structure end)
  end

  defp start_progress(title) do
    token =
      case Progress.begin(title, percentage: 0) do
        {:ok, token} -> token
        {:error, :rejected} -> nil
      end

    {token, 0, System.monotonic_time(:millisecond)}
  end

  # Clients only show the percentage, and one report per file reaches them as
  # one notification per file.
  defp report_progress({token, current, start_time}, size, total, message) do
    previous = percentage(current, total)
    current = current + size
    percentage = percentage(current, total)

    if token && percentage != previous do
      Progress.report(token, message: message, percentage: percentage)
    end

    {token, current, start_time}
  end

  defp percentage(current, total), do: min(100, div(current * 100, total))

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
