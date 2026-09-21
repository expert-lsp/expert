Mix.install([:benchee])

alias Expert.Search.Indexer

path =
  [__DIR__, "..", "..", "engine", "benchmarks", "data", "enum.ex"]
  |> Path.join()
  |> Path.wildcard()
  |> List.first()

{:ok, source} = File.read(path)

Benchee.run(
  %{
    "indexing source code" => fn -> Indexer.Source.index(path, source) end
  },
  profile_after: true
)
