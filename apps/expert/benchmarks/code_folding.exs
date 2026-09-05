# run from apps/expert: mix run --no-start benchmarks/code_folding.exs [baseline_ref]
# includes parsing and folding, excludes document creation and transport.
# use an idle machine for wall-time comparisons.

alias Expert.Document.Context
alias Expert.Provider.Handlers.CodeFolding
alias Forge.Document
alias GenLSP.Requests.TextDocumentFoldingRange
alias GenLSP.Structures.FoldingRangeParams
alias GenLSP.Structures.TextDocumentIdentifier

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
handler_path = "apps/expert/lib/expert/provider/handlers/code_folding.ex"
{source, 0} = System.cmd("git", ["show", "#{baseline}:#{handler_path}"], cd: root)

source
|> String.replace("defmodule #{inspect(CodeFolding)} do", "defmodule FoldingBaseline do")
|> Code.compile_string()

samples = "BENCH_SAMPLES" |> System.get_env("21") |> String.to_integer()
iterations = "BENCH_ITERATIONS" |> System.get_env("30") |> String.to_integer()
true = samples > 0 and iterations > 0
median = fn values -> values |> Enum.sort() |> Enum.at(div(length(values), 2)) end

measure = fn run ->
  # warm up in a fresh process so samples don't share old heaps.
  fn ->
    run.()
    :erlang.garbage_collect()
    {us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> run.() end) end)
    us / iterations / 1000
  end
  |> Task.async()
  |> Task.await(:infinity)
end

IO.puts("baseline #{baseline}, Elixir #{System.version()}, OTP #{System.otp_release()}")
IO.puts("#{samples} alternating samples x #{iterations} calls; median ms per handler call")
IO.puts("file | before | after | less elapsed time")

for path <- [
      handler_path,
      "apps/expert/lib/expert/search/store/backends/sqlite.ex",
      "apps/engine/benchmarks/data/enum.ex"
    ] do
  uri = "file:///folding_bench.ex"
  document = Document.new(uri, File.read!(Path.join(root, path)), 1)
  context = %Context{uri: uri, document: document}

  request = %TextDocumentFoldingRange{
    id: 1,
    params: %FoldingRangeParams{text_document: %TextDocumentIdentifier{uri: uri}}
  }

  before = fn -> FoldingBaseline.handle(request, context) end
  after_run = fn -> CodeFolding.handle(request, context) end

  if before.() != after_run.(), do: raise("folding ranges or order differ for #{path}")

  results =
    for sample <- 1..samples,
        {label, run} <-
          if(rem(sample, 2) == 0,
            do: [after: after_run, before: before],
            else: [before: before, after: after_run]
          ) do
      {label, measure.(run)}
    end

  before_ms = median.(Keyword.get_values(results, :before))
  after_ms = median.(Keyword.get_values(results, :after))
  change = Float.round((1 - after_ms / before_ms) * 100, 2)

  IO.puts(
    "#{Path.basename(path)} | #{Float.round(before_ms, 3)} | " <>
      "#{Float.round(after_ms, 3)} | #{change}%"
  )
end
