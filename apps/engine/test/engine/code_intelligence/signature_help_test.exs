defmodule Engine.CodeIntelligence.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias Engine.CodeIntelligence.SignatureHelp
  alias Forge.Document
  alias Forge.Document.Position

  test "returns local function signatures and the active parameter" do
    source = """
    defmodule SignatureExample do
      @doc "Adds two values."
      @spec add(integer(), integer()) :: integer()
      def add(left, right), do: left + right
      def use_add do
        add(1, nil)
      end
    end
    """

    assert %{
             active_param: 1,
             signatures: [
               %{
                 name: "add",
                 params: ["left", "right"],
                 documentation: "Adds two values.",
                 spec: "@spec add(integer(), integer()) :: integer()"
               }
             ]
           } = signature(source, 6, 11)
  end

  test "returns signatures for loaded modules" do
    assert %{active_param: 1, signatures: [%{name: "map", params: ["enumerable", "fun"]}]} =
             signature("Enum.map([1], &(&1 + 1))", 1, 14)
  end

  test "returns none outside a call" do
    assert :none = signature("value", 1, 6)
  end

  defp signature(source, line, character) do
    document = Document.new("file:///signature_help_test.ex", source, 0)
    position = Position.new(document, line, character)
    SignatureHelp.signature(document, position)
  end
end
