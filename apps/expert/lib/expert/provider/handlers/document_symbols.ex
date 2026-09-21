defmodule Expert.Provider.Handlers.DocumentSymbols do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Symbols
  alias Expert.Document.Context
  alias Forge.Document
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(%Requests.TextDocumentDocumentSymbol{}, %Context{} = context) do
    %Context{document: document, project: project} = context

    symbols =
      project
      |> Symbols.for_document(document)
      |> Enum.map(&to_response(&1, document))

    {:ok, symbols}
  end

  def to_response(%Forge.CodeIntelligence.Symbols.Document{} = root, %Document{} = document) do
    children =
      case root.children do
        list when is_list(list) ->
          Enum.map(list, &to_response(&1, document))

        _ ->
          nil
      end

    %Structures.DocumentSymbol{
      children: children,
      detail: root.detail,
      kind: to_kind(root.type),
      name: root.name,
      range: root.range,
      selection_range: root.detail_range
    }
  end

  defp to_kind(:struct), do: SymbolKind.struct()
  defp to_kind(:module), do: SymbolKind.module()
  defp to_kind(:variable), do: SymbolKind.variable()
  defp to_kind({:function, _}), do: SymbolKind.function()
  defp to_kind({:macro, _}), do: SymbolKind.function()
  defp to_kind({:protocol, _}), do: SymbolKind.module()
  defp to_kind(:module_attribute), do: SymbolKind.constant()
  defp to_kind(:ex_unit_test), do: SymbolKind.method()
  defp to_kind(:ex_unit_describe), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup_all), do: SymbolKind.method()
  defp to_kind(:type), do: SymbolKind.type_parameter()
  defp to_kind(:spec), do: SymbolKind.interface()
  defp to_kind(:file), do: SymbolKind.file()
  defp to_kind(_), do: SymbolKind.string()
end
