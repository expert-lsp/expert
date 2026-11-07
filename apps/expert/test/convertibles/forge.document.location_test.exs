defmodule Forge.Protocol.Convertibles.LocationTest do
  use Expert.Test.Protocol.ConvertibleSupport

  alias GenLSP.Structures

  describe "to_lsp/2" do
    setup [:with_an_open_file]

    test "converts a location with a native range", %{uri: uri, document: document} do
      location = Document.Location.new(valid_range(:native, document), uri)

      assert {:ok, converted} = to_lsp(location, uri)
      assert converted.uri == uri
      assert %Structures.Range{} = converted.range
      assert %Structures.Position{} = converted.range.start
      assert %Structures.Position{} = converted.range.end
    end

    test "converts a location with a source file", %{uri: uri, document: document} do
      location = Document.Location.new(valid_range(:native, document), document)

      assert {:ok, converted} = to_lsp(location, uri)
      assert converted.uri == document.uri
      assert %Structures.Range{} = converted.range
      assert %Structures.Position{} = converted.range.start
      assert %Structures.Position{} = converted.range.end
    end

    test "uses the location's uri", %{uri: uri, document: document} do
      other_uri = "file:///other.ex"
      {:ok, _, _doc} = open_file(other_uri, "goodbye")

      location = Document.Location.new(valid_range(:native, document), other_uri)
      assert {:ok, converted} = to_lsp(location, uri)
      assert converted.uri == other_uri
    end

    test "converts an index range without its document", %{uri: uri} do
      range = %Document.Range{
        start: %Document.Position{line: 1, character: 7, utf16_character: 7},
        end: %Document.Position{line: 1, character: 16, utf16_character: 16}
      }

      assert {:ok, converted} = to_lsp(Document.Location.new(range, "file:///index.ex"), uri)
      assert %Structures.Position{line: 0, character: 7} = converted.range.start
      assert %Structures.Position{line: 0, character: 16} = converted.range.end
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "leaves the location alone", %{uri: uri, document: document} do
      location = Document.Location.new(valid_range(:native, document), uri)

      assert {:ok, converted} = to_native(location, uri)
      assert location == converted
    end
  end
end
