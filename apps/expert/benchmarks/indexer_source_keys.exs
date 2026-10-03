# run from apps/expert after mix compile:
# elixir -pa '_build/dev/lib/*/ebin' -pa '_build/test/lib/*/ebin' benchmarks/indexer_source_keys.exs [baseline_ref]
# compares stream chunk consumption memory and execution time against baseline.

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
indexer_path = "apps/expert/lib/expert/search/indexer.ex"

{baseline_source, 0} =
  System.cmd("git", ["show", "#{baseline}:#{indexer_path}"], cd: root)

current_source = File.read!(Path.join(root, indexer_path))

compile_indexer = fn source, module_name ->
  source
  |> String.replace("defmodule Expert.Search.Indexer do", "defmodule #{module_name} do")
  |> String.replace("defp consume_chunk(", "def consume_chunk(")
  |> String.replace("defp new_stream_state do", "def new_stream_state do")
  |> String.replace("defp collect_stream(", "def collect_stream(")
  |> Code.compile_string()
end

compile_indexer.(baseline_source, BaselineIndexer)
compile_indexer.(current_source, OptimizedIndexer)

Forge.Identifier.start()

# Load enum fixture to generate mock realistic Elixir source entries
enum_path = Path.join(root, "apps/engine/benchmarks/data/enum.ex")
{:ok, base_entries} = Expert.Search.Indexer.Source.index(enum_path, File.read!(enum_path))

build_stream = fn file_count ->
  for copy <- 1..file_count,
      entry <- base_entries do
    mock_entry = %{entry | id: copy * 1_000_000 + (entry.id || 0), path: "lib/mock_#{copy}.ex"}
    {:source, mock_entry, []}
  end
end

inputs = %{
  "100k entries (50 files)" => build_stream.(50),
  "500k entries (250 files)" => build_stream.(250)
}

# 1. Correctness check: ensure both baseline and optimized produce identical output entries
IO.puts("Verifying output parity between baseline (#{baseline}) and current branch...")

Enum.each(inputs, fn {label, stream} ->
  {base_entries, base_state} =
    BaselineIndexer.collect_stream(stream, BaselineIndexer.new_stream_state())

  {opt_entries, opt_state} =
    OptimizedIndexer.collect_stream(stream, OptimizedIndexer.new_stream_state())

  if base_entries != opt_entries do
    raise "Regression detected! Output entries differ between baseline and optimized for #{label}"
  end

  base_keys_count = MapSet.size(base_state.source_keys)
  opt_keys_count = MapSet.size(opt_state.source_keys)
  base_heap = :erts_debug.size(base_state.source_keys) * :erlang.system_info(:wordsize)
  opt_heap = :erts_debug.size(opt_state.source_keys) * :erlang.system_info(:wordsize)

  IO.puts("""
  Parity verified for #{label}:
    - Baseline source_keys count:  #{base_keys_count} (#{Float.round(base_heap / 1024 / 1024, 2)} MB)
    - Optimized source_keys count: #{opt_keys_count} (#{Float.round(opt_heap / 1024 / 1024, 2)} MB)
    - Reduction:                   -#{Float.round((1 - opt_keys_count / base_keys_count) * 100, 1)}% keys, -#{Float.round((1 - opt_heap / base_heap) * 100, 1)}% heap
  """)
end)

IO.puts("Running Benchee benchmark (comparing #{baseline} vs current)...")

Benchee.run(
  %{
    "before (#{baseline})" => fn stream ->
      BaselineIndexer.collect_stream(stream, BaselineIndexer.new_stream_state())
    end,
    "after (optimized)" => fn stream ->
      OptimizedIndexer.collect_stream(stream, OptimizedIndexer.new_stream_state())
    end
  },
  inputs: inputs,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "1")),
  time: String.to_integer(System.get_env("BENCH_TIME", "2")),
  memory_time: String.to_integer(System.get_env("BENCH_MEMORY_TIME", "2"))
)
