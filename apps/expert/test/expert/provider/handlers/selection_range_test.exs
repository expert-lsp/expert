defmodule Expert.Provider.Handlers.SelectionRangeTest do
  use ExUnit.Case

  alias Expert.Document.Context
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers.SelectionRange
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Requests
  alias GenLSP.Structures

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Ast.analyze/1]})
    :ok
  end

  defp build_request(path, positions) do
    uri = Document.Path.ensure_uri(path)

    %Requests.TextDocumentSelectionRange{
      id: Expert.Protocol.Id.next(),
      params: %Structures.SelectionRangeParams{
        text_document: %Structures.TextDocumentIdentifier{uri: uri},
        positions: positions
      }
    }
  end

  defp lsp_range(start_character, end_character) do
    %Structures.Range{
      start: %Structures.Position{line: 0, character: start_character},
      end: %Structures.Position{line: 0, character: end_character}
    }
  end

  describe "selection ranges" do
    test "returns LSP ranges with enclosing parents" do
      uri = "file:///selection.ex"

      :ok = Document.Store.open(uri, "outer(value)", 1)
      {:ok, document} = Document.Store.fetch(uri)

      request = build_request(uri, [%Structures.Position{line: 0, character: 8}])

      context = %Context{uri: uri, document: document, project: nil}

      assert {:ok, native_request} = Convert.to_native(request, document)
      assert {:ok, native_response} = SelectionRange.handle(native_request, context)
      assert {:ok, response} = Convert.to_lsp(native_response)

      value_range = lsp_range(6, 11)
      arguments_range = lsp_range(5, 12)
      call_range = lsp_range(0, 12)

      assert [
               %Structures.SelectionRange{
                 range: ^value_range,
                 parent: %Structures.SelectionRange{
                   range: ^arguments_range,
                   parent: %Structures.SelectionRange{
                     range: ^call_range,
                     parent: nil
                   }
                 }
               }
             ] = response

      assert {:ok, _encoded} =
               Schematic.dump(Requests.TextDocumentSelectionRange.result(), response)
    end

    test "uses the context snapshot when the document store contains a newer version" do
      uri = "file:///snapshot.ex"
      :ok = Document.Store.open(uri, "other(text)", 2)
      document = Document.new(uri, "outer(value)", 1)
      request = build_request(uri, [%Structures.Position{line: 0, character: 8}])
      context = %Context{uri: uri, document: document, project: nil}

      assert {:ok, native_request} = Convert.to_native(request, document)
      assert {:ok, native_response} = SelectionRange.handle(native_request, context)
      assert {:ok, [selection]} = Convert.to_lsp(native_response)
      assert selection.range == lsp_range(6, 11)
    end

    test "analyzes a context document that the store does not contain" do
      document = Document.new("file:///closed.ex", "outer(value)", 1)
      request = build_request(document.uri, [%Structures.Position{line: 0, character: 8}])
      context = %Context{uri: document.uri, document: document, project: nil}

      assert {:ok, native_request} = Convert.to_native(request, document)
      assert {:ok, native_response} = SelectionRange.handle(native_request, context)
      assert {:ok, [selection]} = Convert.to_lsp(native_response)
      assert selection.range == lsp_range(6, 11)
    end

    test "returns no selections for an empty positions list" do
      uri = "file:///empty_positions.ex"
      :ok = Document.Store.open(uri, "outer(value)", 1)
      {:ok, document} = Document.Store.fetch(uri)
      request = build_request(uri, [])
      context = %Context{uri: uri, document: document, project: nil}

      assert {:ok, native_request} = Convert.to_native(request, document)
      assert {:ok, []} = SelectionRange.handle(native_request, context)
    end
  end
end
