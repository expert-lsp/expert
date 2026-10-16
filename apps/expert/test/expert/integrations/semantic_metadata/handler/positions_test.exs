defmodule Expert.Integrations.SemanticMetadata.Handler.PositionsTest do
  use ExUnit.Case, async: true

  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Expert.Protocol.Conversions
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  @line "é 🎸 foo bar"

  setup do
    {:ok, document: Document.new("file:///file.ex", @line <> "\n", 1)}
  end

  defp cursor(document) do
    character = "é 🎸 " |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)

    {:ok, position} =
      Conversions.to_elixir(%GenLSP.Structures.Position{line: 0, character: character}, document)

    position
  end

  test "sends the cursor in codepoints", %{document: document} do
    assert %{line: 1, character: 6} == Positions.cursor(document, cursor(document))
  end

  test "reads the cursor in graphemes for Code.Fragment", %{document: document} do
    assert %Position{line: 1, character: 5} =
             Positions.fragment_cursor(document, cursor(document))
  end

  test "sends a range of the document in codepoints", %{document: document} do
    range = Range.new(Position.new(document, 1, 5), Position.new(document, 1, 8))

    assert %{start: %{line: 1, character: 6}, end: %{line: 1, character: 9}} ==
             Positions.range(document, range)
  end

  test "reads a handler range as a range of the document", %{document: document} do
    provided = %{start: %{line: 1, character: 6}, end: %{line: 1, character: 9}}

    assert {:ok, %Range{start: start, end: stop}} = Positions.to_range(document, provided)
    assert {start.character, stop.character} == {5, 8}

    assert {:ok, lsp} = Conversions.to_lsp(%Range{start: start, end: stop})
    assert {lsp.start.character, lsp.end.character} == {6, 9}
  end

  test "rejects a handler range out of the document or out of order", %{document: document} do
    assert :error =
             Positions.to_range(document, %{
               start: %{line: 3, character: 1},
               end: %{line: 3, character: 2}
             })

    assert :error =
             Positions.to_range(document, %{
               start: %{line: 1, character: 9},
               end: %{line: 1, character: 6}
             })

    assert :error =
             Positions.to_range(document, %{start: %{line: 1}, end: %{line: 1, character: 2}})
  end

  test "replaces the range of a completion item only around the cursor", %{document: document} do
    cursor = cursor(document)
    replaced = %{start: %{line: 1, character: 6}, end: %{line: 1, character: 9}}
    elsewhere = %{start: %{line: 1, character: 10}, end: %{line: 1, character: 13}}
    across = %{start: %{line: 1, character: 6}, end: %{line: 2, character: 1}}

    assert {:ok, {1, 5, 8}} == Positions.completion_range(document, cursor, replaced)
    assert {:ok, nil} == Positions.completion_range(document, cursor, elsewhere)
    assert {:ok, nil} == Positions.completion_range(document, cursor, nil)
    assert :error == Positions.completion_range(document, cursor, across)
  end

  test "keeps the cursor and ranges at the same codepoint columns in a delegated source", %{
    document: document
  } do
    delegated = Document.new("file:///file.ex", "     foo bar\n", 1)

    assert %Position{line: 1, character: 6} =
             Positions.delegated_cursor(document, delegated, cursor(document))

    range = Range.new(Position.new(delegated, 1, 6), Position.new(delegated, 1, 9))

    assert %Range{start: start, end: stop} = Positions.from_delegated(range, delegated, document)
    assert {start.character, stop.character} == {5, 8}
  end
end
