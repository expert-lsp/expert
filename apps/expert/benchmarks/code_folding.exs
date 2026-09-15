# run from apps/expert after mix compile:
# elixir -pa '_build/dev/lib/*/ebin' benchmarks/code_folding.exs [baseline_ref]
# includes parsing and folding, excludes document creation and transport.
# use an idle machine for wall-time comparisons.

alias Expert.Document.Context
alias Expert.Provider.Handlers.CodeFolding
alias Forge.Document
alias GenLSP.Requests.TextDocumentFoldingRange
alias GenLSP.Structures.FoldingRangeParams
alias GenLSP.Structures.TextDocumentIdentifier

Mix.install([{:benchee, "~> 1.5"}])

root = Path.expand("../../..", __DIR__)
baseline = List.first(System.argv()) || "main"
handler_path = "apps/expert/lib/expert/provider/handlers/code_folding.ex"
{source, 0} = System.cmd("git", ["show", "#{baseline}:#{handler_path}"], cd: root)

source
|> String.replace("defmodule #{inspect(CodeFolding)} do", "defmodule FoldingBaseline do")
|> Code.compile_string()

inputs =
  Map.new(
    [
      handler_path,
      "apps/expert/lib/expert/search/store/backends/sqlite.ex",
      "apps/engine/benchmarks/data/enum.ex"
    ],
    fn path ->
      uri = "file:///folding_bench.ex"
      document = Document.new(uri, File.read!(Path.join(root, path)), 1)
      context = %Context{uri: uri, document: document}

      request = %TextDocumentFoldingRange{
        id: 1,
        params: %FoldingRangeParams{text_document: %TextDocumentIdentifier{uri: uri}}
      }

      if FoldingBaseline.handle(request, context) != CodeFolding.handle(request, context),
        do: raise("folding ranges or order differ for #{path}")

      {Path.basename(path), {request, context}}
    end
  )

IO.puts("baseline #{baseline}")

Benchee.run(
  %{
    "before" => fn {request, context} -> FoldingBaseline.handle(request, context) end,
    "after" => fn {request, context} -> CodeFolding.handle(request, context) end
  },
  inputs: inputs,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "2")),
  time: String.to_integer(System.get_env("BENCH_TIME", "5"))
)
