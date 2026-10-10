defmodule Expert.Integrations.SemanticMetadata.Delegation do
  @moduledoc false

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  def analyze(%Analysis{document: document}, source, %Position{} = position) do
    delegated = Document.new(document.uri, source, document.version, "elixir")
    {Ast.analyze(delegated), Position.new(delegated, position.line, position.character)}
  end

  def to_document_range(%Range{start: start, end: stop}, %Document{} = document) do
    Range.new(
      Position.new(document, start.line, start.character),
      Position.new(document, stop.line, stop.character)
    )
  end
end
