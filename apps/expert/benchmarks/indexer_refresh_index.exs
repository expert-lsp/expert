# run from apps/expert after mix compile:
# elixir -pa '_build/dev/lib/*/ebin' -pa '_build/test/lib/*/ebin' benchmarks/indexer_refresh_index.exs [baseline_ref]
# compares memory allocation and execution time between collect_stream and streaming refresh_index.

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
indexer_path = "apps/expert/lib/expert/search/indexer.ex"

{baseline_source, 0} =
  System.cmd("git", ["show", "#{baseline}:#{indexer_path}"], cd: root)

current_source = File.read!(Path.join(root, indexer_path))

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

  def handle_call({:apply_index_update, update, paths_to_clear}, _from, state) do
    if is_function(update, 1) do
      count = :counters.new(1, [:atomics])

      res =
        update.(fn chunk ->
          :counters.add(count, 1, length(chunk))
          :ok
        end)

      case res do
        {:ok, final_state} ->
          {:reply, {:ok, final_state},
           %{state | entries_count: :counters.get(count, 1), paths_to_clear: paths_to_clear}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:reply, :ok, %{state | entries_count: length(update), paths_to_clear: paths_to_clear}}
    end
  end
end

defmodule RealSqliteStore do
  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Project

  def start_link(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "expert-bench-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)

    project = Project.new("file://#{root}")
    Project.ensure_workspace(project)
    Sqlite.destroy_all(project)

    {:ok, pid} =
      Sqlite.start_link(project,
        runtime_versions: %{erlang: System.otp_release(), elixir: System.version()}
      )

    {:ok, :empty} = Sqlite.prepare(pid)
    {:ok, %{project: project, pid: pid, root: root}}
  end

  def stop(%{pid: pid, root: root}) do
    GenServer.stop(pid)
    File.rm_rf!(root)
  end

  def insert(%{project: project}, entries) do
    Sqlite.insert(project, entries)
  end

  def apply_index_update(%{project: project}, update, paths_to_clear) do
    case Sqlite.apply_index_update(project, update, paths_to_clear) do
      {:ok, _, result} -> {:ok, result}
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end
end

compile_indexer = fn source, module_name ->
  source
  |> String.replace("defmodule Expert.Search.Indexer do", "defmodule #{module_name} do")
  |> String.replace("defp collect_stream(", "def collect_stream(")
  |> String.replace("defp stream_into_store(", "def stream_into_store(")
  |> String.replace("defp refresh_store(", "def refresh_store(")
  |> String.replace("defp persist_stream(", "def persist_stream(")
  |> String.replace("defp consume_chunk(", "def consume_chunk(")
  |> String.replace("defp new_stream_state do", "def new_stream_state do")
  |> String.replace("defp manifest_entries(", "def manifest_entries(")
  |> Code.compile_string()
end

compile_indexer.(baseline_source, BaselineIndexer)
compile_indexer.(current_source, OptimizedIndexer)

defmodule Runner do
  @entry_chunk_size 4_000

  def run_baseline(stream, paths_to_clear, store, module \\ MockStore) do
    {entries, state} = BaselineIndexer.collect_stream(stream, BaselineIndexer.new_stream_state())
    :ok = module.apply_index_update(store, entries, paths_to_clear)
    {:ok, BaselineIndexer.manifest_entries(state)}
  end

  def run_optimized(stream, paths_to_clear, store, module \\ MockStore) do
    update = fn write_batch ->
      stream
      |> Stream.chunk_every(@entry_chunk_size)
      |> Enum.reduce_while(OptimizedIndexer.new_stream_state(), fn chunk, state ->
        {entries, state} = OptimizedIndexer.consume_chunk(chunk, state)

        case write_batch.(entries) do
          :ok -> {:cont, state}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _} = error -> error
        state -> {:ok, state}
      end
    end

    res = module.apply_index_update(store, update, paths_to_clear)

    state =
      case res do
        {:ok, state} -> state
        _ -> OptimizedIndexer.new_stream_state()
      end

    {:ok, OptimizedIndexer.manifest_entries(state)}
  end
end

Forge.Identifier.start()

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
  paths_to_clear = Enum.map(1..file_count, fn i -> "lib/mock_#{i}.ex" end)

  {:ok, store1} = MockStore.start_link()
  {:ok, store2} = MockStore.start_link()

  {:ok, base_manifest} = Runner.run_baseline(build_stream.(file_count), paths_to_clear, store1)
  {:ok, opt_manifest} = Runner.run_optimized(build_stream.(file_count), paths_to_clear, store2)

  if base_manifest != opt_manifest do
    raise "Regression detected! Manifest output differs between baseline and optimized for #{label}"
  end

  base_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_stream.(file_count), paths_to_clear, store)
    end)

  opt_peak_bytes =
    measure_peak_heap.(fn ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_stream.(file_count), paths_to_clear, store)
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

"=" |> String.duplicate(70) |> IO.puts()
IO.puts("Measuring real SQLite database transactions (disk I/O & commits)...")
"=" |> String.duplicate(70) |> IO.puts()

Enum.each(inputs, fn {label, file_count} ->
  paths_to_clear = Enum.map(1..file_count, fn i -> "lib/mock_#{i}.ex" end)
  stream_data = build_stream.(file_count) |> Enum.to_list()

  {:ok, store1} = RealSqliteStore.start_link("base")

  {base_us, {:ok, _}} =
    :timer.tc(fn ->
      Runner.run_baseline(stream_data, paths_to_clear, store1, RealSqliteStore)
    end)

  RealSqliteStore.stop(store1)

  {:ok, store2} = RealSqliteStore.start_link("opt")

  {opt_us, {:ok, _}} =
    :timer.tc(fn ->
      Runner.run_optimized(stream_data, paths_to_clear, store2, RealSqliteStore)
    end)

  RealSqliteStore.stop(store2)

  base_ms = Float.round(base_us / 1000, 2)
  opt_ms = Float.round(opt_us / 1000, 2)
  ratio = Float.round(opt_ms / base_ms, 2)
  diff = Float.round(opt_ms - base_ms, 2)

  IO.puts("""
  [#{label} - Real SQLite]
    - Baseline (Single Transaction): #{base_ms} ms
    - Optimized (Single Trans Stream): #{opt_ms} ms (diff: #{if diff >= 0, do: "+"}#{diff} ms, #{ratio}x)
  """)
end)

IO.puts("Running Benchee benchmark measuring memory allocations and throughput...")

bench_inputs =
  Map.new(inputs, fn {label, file_count} ->
    paths_to_clear = Enum.map(1..file_count, fn i -> "lib/mock_#{i}.ex" end)
    {label, {file_count, paths_to_clear}}
  end)

Benchee.run(
  %{
    "before (#{baseline})" => fn {file_count, paths_to_clear} ->
      {:ok, store} = MockStore.start_link()
      Runner.run_baseline(build_stream.(file_count), paths_to_clear, store)
      GenServer.stop(store)
    end,
    "after (optimized)" => fn {file_count, paths_to_clear} ->
      {:ok, store} = MockStore.start_link()
      Runner.run_optimized(build_stream.(file_count), paths_to_clear, store)
      GenServer.stop(store)
    end
  },
  inputs: bench_inputs,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "1")),
  time: String.to_integer(System.get_env("BENCH_TIME", "2")),
  memory_time: String.to_integer(System.get_env("BENCH_MEMORY_TIME", "2"))
)
