defmodule Expert.Search.Indexer.Source do
  alias Expert.EngineApi
  alias Expert.Search.Indexer
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Document

  def index(path, source, extractors \\ nil) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors)
  end

  def index(path, source, extractors, project) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors, project)
  end

  def index_document(%Document{} = document, extractors \\ nil) do
    document
    |> Ast.analyze(expand_uses: true)
    |> Indexer.Quoted.index(extractors)
  end

  # Project compiled files have their imported calls resolved by the compiler tracer.
  # The tracer does not run for script files, so we need to expand their uses to resolve them.
  def index_document(%Document{} = document, extractors, project) do
    analysis = Ast.analyze(document)
    imported_calls = Reducer.built_imported_calls(analysis, project)

    analysis =
      if traced?(analysis, imported_calls) do
        analysis
      else
        EngineApi.analyze(project, document, expand_uses: true)
      end

    Indexer.Quoted.index(analysis, extractors, project, imported_calls)
  end

  defp traced?(analysis, imported_calls) do
    case Reducer.defined_modules(analysis) do
      [] -> false
      modules -> Enum.all?(modules, &Map.has_key?(imported_calls, &1))
    end
  end
end
