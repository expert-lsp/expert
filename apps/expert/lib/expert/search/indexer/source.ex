defmodule Expert.Search.Indexer.Source do
  alias Expert.EngineApi
  alias Expert.Search.Indexer
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

  def index_document(%Document{} = document, extractors, project) do
    project
    |> EngineApi.analyze(document, expand_uses: true)
    |> Indexer.Quoted.index(extractors, project)
  end
end
