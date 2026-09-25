defmodule Expert.Provider.Handlers.SelectionRange do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def requires_engine? do
    false
  end

  @impl true
  def handle(
        %Requests.TextDocumentSelectionRange{params: %Structures.SelectionRangeParams{} = params},
        %Context{document: document}
      ) do
    positions = params.positions
    analysis = document_analysis(document)

    selections =
      for ranges <- Ast.SelectionRanges.ranges(analysis, positions) do
        Enum.reduce(ranges, nil, fn range, parent ->
          %Structures.SelectionRange{range: range, parent: parent}
        end)
      end

    {:ok, selections}
  end

  defp document_analysis(document) do
    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, ^document, %Ast.Analysis{} = analysis} ->
        analysis

      {:ok, _other_document, %Ast.Analysis{}} ->
        Ast.analyze(document)

      {:error, :not_open} ->
        Ast.analyze(document)
    end
  end
end
