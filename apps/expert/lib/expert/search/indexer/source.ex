defmodule Expert.Search.Indexer.Source do
  alias Expert.EngineApi
  alias Expert.Search.Indexer
  alias Forge.Ast
  alias Forge.Document

  def index(path, source, extractors \\ nil) do
    if template?(path, source) do
      {:ok, []}
    else
      path
      |> Document.new(source, 1)
      |> index_document(extractors)
    end
  end

  def index(path, source, extractors, project) do
    if template?(path, source) do
      {:ok, []}
    else
      path
      |> Document.new(source, 1)
      |> index_document(extractors, project)
    end
  end

  def index_document(%Document{} = document, extractors \\ nil) do
    if template?(document.path, Document.to_string(document)) do
      {:ok, []}
    else
      document
      |> Ast.analyze(expand_uses: true)
      |> Indexer.Quoted.index(extractors)
    end
  end

  def index_document(%Document{} = document, extractors, project) do
    if template?(document.path, Document.to_string(document)) do
      {:ok, []}
    else
      project
      |> EngineApi.analyze(document, expand_uses: true)
      |> Indexer.Quoted.index(extractors, project)
    end
  end

  defp template?(path, source) do
    Forge.Path.template_path?(path) or Ast.eex_template?(source)
  end
end
