defmodule Expert.Integrations.SemanticMetadata.Delegation do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  def analyze(%Analysis{document: document}, source, %Position{} = position) do
    delegated = Document.new(document.uri, source, document.version, "elixir")
    {Ast.analyze(delegated), Positions.delegated_cursor(document, delegated, position)}
  end

  def to_document_range(%Range{} = range, %Document{} = delegated, %Document{} = document),
    do: Positions.from_delegated(range, delegated, document)
end
