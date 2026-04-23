defmodule Expert.Protocol.ConversionsTest do
  use ExUnit.Case

  alias Expert.Protocol.Conversions
  alias Forge.Document
  alias Forge.Document.Position, as: ExPosition
  alias GenLSP.Structures.Position, as: LSPosition

  defp lsp_position(line, char) do
    %LSPosition{line: line, character: char}
  end

  defp ex_position(document, line, char) do
    ExPosition.new(document, line, char)
  end

  defp doc(text) do
    Document.new("file:///file.ex", text, 0)
  end

  describe "to_elixir/2 for positions" do
    test "empty" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 0), doc(""))
      assert %ExPosition{line: 1, character: 1} = pos
    end

    test "single first char" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 0), doc("abcde"))
      assert %ExPosition{line: 1, character: 1} = pos
    end

    test "single line" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 0), doc("abcde"))
      assert %ExPosition{line: 1, character: 1} = pos
    end

    test "single line utf8" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 6), doc("🏳️‍🌈abcde"))
      assert %ExPosition{line: 1, character: 15} = pos
    end

    test "multi line" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(1, 1), doc("abcde\n1234"))
      assert %ExPosition{line: 2, character: 2} = pos
    end

    # LSP spec 3.17 https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position
    # position character If the character value is greater than the line length it defaults back to the line length

    test "position > line length of an empty document" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 15), doc(""))
      assert %ExPosition{line: 1, character: 1} = pos
    end

    test "position > line length of a document with characters" do
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(0, 15), doc("abcde"))
      assert %ExPosition{line: 1, character: 16} = pos
    end

    #  This is not specified in LSP but some clients fail to synchronize text properly
    test "position > line length multi line after last line" do
      # the behavior that conversions does is to clamp at the start line of the end of the
      # document.
      assert {:ok, pos} = Conversions.to_elixir(lsp_position(8, 2), doc("abcde\n1234"))
      assert %ExPosition{line: 3, character: 1} = pos
    end

    test "document is nil" do
      assert Conversions.to_elixir(
               %GenLSP.Structures.Range{end: lsp_position(0, 0), start: lsp_position(0, 0)},
               nil
             ) == {:error, {:invalid_document, nil}}

      assert Conversions.to_elixir(lsp_position(0, 0), nil) == {:error, {:invalid_document, nil}}

      assert Conversions.to_elixir(%{range: %{start: 0, end: 0}}, nil) ==
               {:error, {:invalid_document, nil}}
    end
  end

  describe "to_lsp/2 for positions" do
    test "empty" do
      doc = doc("")
      assert {:ok, pos} = Conversions.to_lsp(ex_position(doc, 1, 1))
      assert %LSPosition{line: 0, character: 0} == pos
    end

    test "single line first char" do
      doc = doc("abcde")
      assert {:ok, pos} = Conversions.to_lsp(ex_position(doc, 1, 1))
      assert %LSPosition{line: 0, character: 0} == pos
    end

    test "single line" do
      doc = doc("abcde")
      assert {:ok, pos} = Conversions.to_lsp(ex_position(doc, 1, 2))
      assert %LSPosition{line: 0, character: 1} == pos
    end

    test "single line utf8" do
      doc = doc("🏳️‍🌈abcde")
      assert {:ok, pos} = Conversions.to_lsp(ex_position(doc, 1, 2))
      assert %LSPosition{character: 6, line: 0} == pos
    end

    test "multi line" do
      doc = doc("abcde\n1234")
      assert {:ok, pos} = Conversions.to_lsp(ex_position(doc, 2, 2))
      assert %LSPosition{character: 1, line: 1} == pos
    end
  end
end
