defmodule Expert.Integrations.EExTest do
  use ExUnit.Case, async: true

  alias Expert.Integrations.EEx

  test "keeps the code of earlier tags in the delegated source" do
    request = request("<% import Enum, only: [map: 2] %>\n<%= ma| %>")

    assert %{delegate: %{source: "   import Enum, only: [map: 2] ; \n    ma ; "}} =
             EEx.complete(request)
  end

  test "keeps code at its template position and blanks everything else" do
    request = request("a <%= foo %> b <%= ba| %>")

    assert %{delegate: %{source: "      foo ;        ba ; "}} = EEx.complete(request)
  end

  test "keeps blocks closed across tags and lines" do
    request = request("<%= for x <- xs do %>\n  <%= x| %>\n<% end %>")

    assert %{delegate: %{source: source}} = EEx.complete(request)
    assert source == "    for x <- xs do ; \n      x ; \n   end ; "
    assert {:ok, _quoted} = Code.string_to_quoted(source)
  end

  test "counts a multi-byte character as one column" do
    assert EEx.complete(request("<p>é</p><%= Enum.ma| %>")) ==
             EEx.complete(request("<p>e</p><%= Enum.ma| %>"))
  end

  test "completes inside an unclosed tag" do
    request = request("<%= fo|")

    assert %{delegate: %{source: "    fo;"}} = EEx.complete(request)
  end

  test "ignores cursor positions outside EEx expressions" do
    request = request("template text|")
    assert %{mode: :override, items: [], incomplete?: false} = EEx.complete(request)
  end

  defp request(source) do
    [before, after_cursor] = String.split(source, "|", parts: 2)
    lines = String.split(before, "\n")

    %{
      language_id: "eex",
      source: before <> after_cursor,
      position: %{
        line: length(lines),
        character: length(String.to_charlist(List.last(lines))) + 1
      }
    }
  end
end
