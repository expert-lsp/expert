defmodule Expert.Search.Indexer.Source do
  alias Expert.Search.Indexer
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project

  def index(path, source, extractors \\ nil) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors)
  end

  def index(path, source, extractors, %Project{} = project) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors, project)
  end

  def index_document(%Document{} = document, extractors \\ nil) do
    document
    |> Ast.analyze()
    |> Indexer.Quoted.index(extractors)
  end

  def index_document(%Document{} = document, extractors, %Project{} = project) do
    document
    |> Ast.analyze()
    |> Indexer.Quoted.index(extractors, project)
  end
end
