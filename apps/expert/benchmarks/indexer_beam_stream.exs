# run from apps/expert after mix compile:
# elixir -pa '_build/dev/lib/*/ebin' -pa '_build/test/lib/*/ebin' benchmarks/indexer_beam_stream.exs
# compares memory allocation and execution time between Enum.to_list and pure streaming BEAM indexing up to 2.5M entries.

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
Forge.Identifier.start()

# Load enum fixture to generate realistic Elixir entries
enum_path = Path.join(root, "apps/engine/benchmarks/data/enum.ex")
{:ok, base_entries} = Expert.Search.Indexer.Source.index(enum_path, File.read!(enum_path))
entries_per_file = length(base_entries)
IO.puts("Base fixture #{Path.basename(enum_path)} produces #{entries_per_file} entries per module.")

build_beam_stream = fn file_count ->
  Stream.flat_map(1..file_count, fn copy ->
    path = "ebin/Elixir.MockModule#{copy}.beam"
    source_path = "lib/mock_module_#{copy}.ex"

    manifest_entry = %Expert.Search.Indexer.Manifest.Entry{
      input_path: path,
      output_path: source_path,
      kind: :beam,
      mtime: 1,
      size: 100
    }

    [first | rest] = base_entries

    [
      {%{first | id: copy * 10_000_000 + (first.id || 0), path: source_path}, [manifest_entry]}
      | Enum.map(rest, fn entry ->
          {%{entry | id: copy * 10_000_000 + (entry.id || 0), path: source_path}, []}
        end)
    ]
  end)
end

defmodule MockStore do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    {:ok, %{entries_count: 0}}
  end

  def insert(pid, entries) do
    GenServer.call(pid, {:insert, entries}, :infinity)
  end

  def entries_count(pid) do
    GenServer.call(pid, :entries_count, :infinity)
  end

  def handle_call({:insert, entries}, _from, state) do
    {:reply, :ok, %{state | entries_count: state.entries_count + length(entries)}}
  end

  def handle_call(:entries_count, _from, state) do
    {:reply, state.entries_count, state}
  end
end

defmodule Runner do
  @entry_chunk_size 4_000

  def run_baseline(stream, store_pid) do
    # Baseline: Materialize entire BEAM stream into memory list
    beam_items = Enum.to_list(stream)

    beam_stream =
      beam_items
      |> Stream.map(fn {entry, manifest_entries} -> {:beam, entry, manifest_entries} end)

    stream_into_store(beam_stream, store_pid)
  end

  def run_optimized(stream, store_pid) do
    # Optimized: Stream directly without materializing list
    beam_stream =
      stream
      |> Stream.map(fn {entry, manifest_entries} -> {:beam, entry, manifest_entries} end)

    stream_into_store(beam_stream, store_pid)
  end

  defp stream_into_store(stream, store_pid) do
    state = %{manifest_entries: [], source_keys: MapSet.new()}

    result =
      stream
      |> Stream.chunk_every(@entry_chunk_size)
      |> Enum.reduce_while(state, fn chunk, state ->
        {entries, state} = consume_chunk(chunk, state)

        case MockStore.insert(store_pid, entries) do
          :ok -> {:cont, state}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      state -> {:ok, Enum.reverse(state.manifest_entries)}
    end
  end

  defp consume_chunk(chunk, state) do
    Enum.reduce(chunk, {[], state}, fn {origin, entry, manifest_entries}, {entries, state} ->
      state = %{state | manifest_entries: Enum.reverse(manifest_entries, state.manifest_entries)}
      consume_entry(origin, entry, entries, state)
    end)
  end

  defp consume_entry(_origin, nil, entries, state), do: {entries, state}
  defp consume_entry(:beam, entry, entries, state), do: {[entry | entries], state}
end

measure_peak_heap = fn fun ->
  parent = self()

  pid =
    spawn(fn ->
      receive do
        :start ->
          fun.()
          send(parent, {:done, :erlang.process_info(self(), :total_heap_size)})
      end
    end)

  monitor_ref = Process.monitor(pid)
  send(pid, :start)

  peak_heap =
    fn ->
      case :erlang.process_info(pid, :total_heap_size) do
        {:total_heap_size, size} -> size
        _ -> 0
      end
    end
    |> Stream.repeatedly()
    |> Stream.take_while(fn _ -> Process.alive?(pid) end)
    |> Enum.max(fn -> 0 end)

  receive do
    {:done, {:total_heap_size, final_heap}} ->
      Process.demonitor(monitor_ref, [:flush])
      max(peak_heap, final_heap) * :erlang.system_info(:wordsize)

    {:done, _} ->
      Process.demonitor(monitor_ref, [:flush])
      peak_heap * :erlang.system_info(:wordsize)

    {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
      raise "Worker process failed: #{inspect(reason)}"
  end
end

inputs = %{
  "500k entries (327 modules)" => 327,
  "1.0M entries (654 modules)" => 654,
  "2.5M entries (1,635 modules)" => 1635,
  "10.0M entries (6,540 modules)" => 6540
}

"=" |> String.duplicate(70) |> IO.puts()
IO.puts("1. Output Parity & Peak Process Heap Measurement (up to 10.0M entries)")
"=" |> String.duplicate(70) |> IO.puts()

Enum.each(inputs, fn {label, file_count} ->
  {:ok, store1} = MockStore.start_link()
  {:ok, store2} = MockStore.start_link()

  {:ok, base_manifest} = Runner.run_baseline(build_beam_stream.(file_count), store1)
  {:ok, opt_manifest} = Runner.run_optimized(build_beam_stream.(file_count), store2)

  count1 = MockStore.entries_count(store1)
  count2 = MockStore.entries_count(store2)

  if length(base_manifest) != length(opt_manifest) or count1 != count2 do
    raise "Parity mismatch for #{label}: entries #{count1} vs #{count2}, manifest #{length(base_manifest)} vs #{length(opt_manifest)}"
  end

  GenServer.stop(store1)
  GenServer.stop(store2)

  base_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_beam_stream.(file_count), store)
      GenServer.stop(store)
    end)

  opt_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_beam_stream.(file_count), store)
      GenServer.stop(store)
    end)

  base_mb = Float.round(base_peak_bytes / 1024 / 1024, 2)
  opt_mb = Float.round(opt_peak_bytes / 1024 / 1024, 2)
  saved_mb = Float.round(base_mb - opt_mb, 2)
  saved_pct = Float.round((1 - opt_peak_bytes / base_peak_bytes) * 100, 1)

  IO.puts("""
  [#{label}]
    - Entries Produced:        #{count1} entries, #{length(base_manifest)} manifest entries (100% PARITY)
    - Baseline Peak Heap:      #{base_mb} MB
    - Optimized Peak Heap:     #{opt_mb} MB
    - Heap Memory Saved:       #{saved_mb} MB reduction (-#{saved_pct}%)
  """)
end)

"=" |> String.duplicate(70) |> IO.puts()
IO.puts("2. Benchee Execution (Time & Total Allocation at 10.0M entries)")
"=" |> String.duplicate(70) |> IO.puts()

Benchee.run(
  %{
    "Baseline (Enum.to_list)" => fn file_count ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_beam_stream.(file_count), store)
      GenServer.stop(store)
    end,
    "Optimized (Stream)" => fn file_count ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_beam_stream.(file_count), store)
      GenServer.stop(store)
    end
  },
  inputs: %{
    "10.0M entries" => 6540
  },
  warmup: 1,
  time: 8,
  memory_time: 2
)
