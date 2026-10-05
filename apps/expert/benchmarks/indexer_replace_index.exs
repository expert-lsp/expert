# run from apps/expert after mix compile:
# elixir -pa '_build/dev/lib/*/ebin' -pa '_build/test/lib/*/ebin' benchmarks/indexer_replace_index.exs [baseline_ref]
# compares memory allocation and execution time between collect_stream and streaming replace_index.

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
indexer_path = "apps/expert/lib/expert/search/indexer.ex"

{baseline_source, 0} =
  System.cmd("git", ["show", "#{baseline}:#{indexer_path}"], cd: root)

current_source = File.read!(Path.join(root, indexer_path))

# Simulated Search Store GenServer to accurately capture process boundary message passing
defmodule MockStore do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    {:ok, %{entries_count: 0, paths_to_clear: []}}
  end

  def replace(pid, entries) do
    GenServer.call(pid, {:replace, entries}, :infinity)
  end

  def insert(pid, entries) do
    GenServer.call(pid, {:insert, entries}, :infinity)
  end

  def apply_index_update(pid, entries, paths_to_clear) do
    GenServer.call(pid, {:apply_index_update, entries, paths_to_clear}, :infinity)
  end

  def handle_call({:replace, entries}, _from, state) do
    {:reply, :ok, %{state | entries_count: length(entries)}}
  end

  def handle_call({:insert, entries}, _from, state) do
    {:reply, :ok, %{state | entries_count: state.entries_count + length(entries)}}
  end

  def handle_call({:apply_index_update, entries, paths_to_clear}, _from, state) do
    {:reply, :ok, %{state | entries_count: length(entries), paths_to_clear: paths_to_clear}}
  end
end

compile_indexer = fn source, module_name ->
  source
  |> String.replace("defmodule Expert.Search.Indexer do", "defmodule #{module_name} do")
  |> String.replace("defp collect_stream(", "def collect_stream(")
  |> String.replace("defp persist_stream(", "def persist_stream(")
  |> String.replace("defp consume_chunk(", "def consume_chunk(")
  |> String.replace("defp new_stream_state do", "def new_stream_state do")
  |> String.replace("defp manifest_entries(", "def manifest_entries(")
  |> String.replace("defp stored_paths_to_clear(", "def stored_paths_to_clear(")
  |> Code.compile_string()
end

compile_indexer.(baseline_source, BaselineIndexer)
compile_indexer.(current_source, OptimizedIndexer)

defmodule Runner do
  @entry_chunk_size 4_000

  def run_baseline(stream, path_to_ids, store_pid) do
    {entries, state} = BaselineIndexer.collect_stream(stream, BaselineIndexer.new_stream_state())
    indexed_paths = MapSet.new(entries, & &1.path)
    paths_to_clear = BaselineIndexer.stored_paths_to_clear(path_to_ids, indexed_paths)
    :ok = MockStore.apply_index_update(store_pid, entries, paths_to_clear)
    {:ok, BaselineIndexer.manifest_entries(state)}
  end

  def run_optimized(stream, _path_to_ids, store_pid) do
    :ok = MockStore.replace(store_pid, [])

    {:ok, state} =
      stream
      |> Stream.chunk_every(@entry_chunk_size)
      |> Enum.reduce_while({:ok, OptimizedIndexer.new_stream_state()}, fn chunk, {:ok, state} ->
        {entries, state} = OptimizedIndexer.consume_chunk(chunk, state)

        case MockStore.insert(store_pid, entries) do
          :ok -> {:cont, {:ok, state}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    {:ok, OptimizedIndexer.manifest_entries(state)}
  end
end

Forge.Identifier.start()

# Load enum fixture to generate mock realistic Elixir source entries
enum_path = Path.join(root, "apps/engine/benchmarks/data/enum.ex")
{:ok, base_entries} = Expert.Search.Indexer.Source.index(enum_path, File.read!(enum_path))

build_stream = fn file_count ->
  Stream.flat_map(1..file_count, fn copy ->
    path = "lib/mock_#{copy}.ex"

    manifest_entry = %Expert.Search.Indexer.Manifest.Entry{
      input_path: path,
      output_path: path,
      kind: :source,
      mtime: 1,
      size: 100
    }

    [first | rest] = base_entries

    [
      {:source, %{first | id: copy * 1_000_000 + (first.id || 0), path: path}, [manifest_entry]}
      | Enum.map(rest, fn entry ->
          {:source, %{entry | id: copy * 1_000_000 + (entry.id || 0), path: path}, []}
        end)
    ]
  end)
end

inputs = %{
  "100k entries (50 files)" => 50,
  "500k entries (250 files)" => 250,
  "1M entries (500 files)" => 500
}

# 1. Output Parity & Peak Heap Measurement
"=" |> String.duplicate(70) |> IO.puts()

IO.puts(
  "Verifying output parity & peak heap between baseline (#{baseline}) and current branch..."
)

"=" |> String.duplicate(70) |> IO.puts()

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

Enum.each(inputs, fn {label, file_count} ->
  path_to_ids = Map.new(1..file_count, fn i -> {"lib/mock_#{i}.ex", i} end)

  {:ok, store1} = MockStore.start_link()
  {:ok, store2} = MockStore.start_link()

  {:ok, base_manifest} = Runner.run_baseline(build_stream.(file_count), path_to_ids, store1)
  {:ok, opt_manifest} = Runner.run_optimized(build_stream.(file_count), path_to_ids, store2)

  if base_manifest != opt_manifest do
    raise "Regression detected! Manifest output differs between baseline and optimized for #{label}"
  end

  base_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_stream.(file_count), path_to_ids, store)
    end)

  opt_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_stream.(file_count), path_to_ids, store)
    end)

  base_mb = Float.round(base_peak_bytes / 1024 / 1024, 2)
  opt_mb = Float.round(opt_peak_bytes / 1024 / 1024, 2)
  saved_mb = Float.round(base_mb - opt_mb, 2)
  saved_pct = Float.round((1 - opt_peak_bytes / base_peak_bytes) * 100, 1)

  IO.puts("""
  [#{label}]
    - Output Manifest Parity:  VERIFIED (identical #{length(base_manifest)} manifest entries)
    - Baseline Peak Heap:      #{base_mb} MB
    - Optimized Peak Heap:     #{opt_mb} MB
    - Peak Heap Saved:         -#{saved_mb} MB (-#{saved_pct}%)
  """)
end)

# 2. Benchee Execution
IO.puts("Running Benchee benchmark measuring memory allocations and throughput...")

bench_inputs =
  Map.new(inputs, fn {label, file_count} ->
    path_to_ids = Map.new(1..file_count, fn i -> {"lib/mock_#{i}.ex", i} end)
    {label, {file_count, path_to_ids}}
  end)

Benchee.run(
  %{
    "before (#{baseline})" => fn {file_count, path_to_ids} ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_stream.(file_count), path_to_ids, store)
      GenServer.stop(store)
    end,
    "after (optimized)" => fn {file_count, path_to_ids} ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_stream.(file_count), path_to_ids, store)
      GenServer.stop(store)
    end
  },
  inputs: bench_inputs,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "1")),
  time: String.to_integer(System.get_env("BENCH_TIME", "2")),
  memory_time: String.to_integer(System.get_env("BENCH_MEMORY_TIME", "2"))
)
