# run from apps/expert after mix compile:
# elixir benchmarks/fuzzy_scorer_preprocess.exs [baseline_ref]
# compares Fuzzy.Scorer.preprocess/1 execution time and allocated memory against baseline.

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
scorer_path = "apps/expert/lib/expert/search/fuzzy/scorer.ex"

{baseline_source, 0} =
  System.cmd("git", ["show", "#{baseline}:#{scorer_path}"], cd: root)

current_source = File.read!(Path.join(root, scorer_path))

compile_scorer = fn source, module_name ->
  source
  |> String.replace("defmodule Expert.Search.Fuzzy.Scorer do", "defmodule #{module_name} do")
  |> Code.compile_string()
end

compile_scorer.(baseline_source, BaselineScorer)
compile_scorer.(current_source, OptimizedScorer)

# Generate realistic subjects (modules, functions, and nested namespaces)
prefixes = [
  "MyApp.Accounts.User",
  "MyApp.Billing.Subscription",
  "Phoenix.LiveView.Socket",
  "Expert.Search.Indexer",
  "Elixir.Enum"
]

suffixes = for i <- 1..10_000, do: "action_#{i}/#{rem(i, 4)}"
subjects_50k = for p <- prefixes, s <- suffixes, do: "#{p}.#{s}"
subjects_10k = Enum.take(subjects_50k, 10_000)

# 1. Output Parity & Edge Case Verification
IO.puts("Verifying output parity between baseline (#{baseline}) and current branch...")

for s <- subjects_50k do
  if BaselineScorer.preprocess(s) != OptimizedScorer.preprocess(s) do
    raise "Output mismatch detected on subject #{inspect(s)}!"
  end
end

edge_cases = [
  "",
  ".",
  "..",
  "...",
  "SimpleFunction",
  "NoDotsHere",
  ".leading_dot",
  "trailing_dot.",
  "multiple..dots...here",
  "Unicode.Grapheme.áéíóú.test/2"
]

for s <- edge_cases do
  if BaselineScorer.preprocess(s) != OptimizedScorer.preprocess(s) do
    raise "Edge case mismatch detected on subject #{inspect(s)}!"
  end
end

IO.puts("Parity verified 100% across 50,000 subjects and all edge cases.")

# 2. Benchee Benchmark
Benchee.run(
  %{
    "after (optimized)" => fn list -> Enum.each(list, &OptimizedScorer.preprocess/1) end,
    "before (baseline)" => fn list -> Enum.each(list, &BaselineScorer.preprocess/1) end
  },
  inputs: %{
    "10k subjects" => subjects_10k,
    "50k subjects" => subjects_50k
  },
  memory_time: 2,
  warmup: 1,
  time: 2
)
