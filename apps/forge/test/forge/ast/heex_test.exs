defmodule Forge.Ast.HeexTest do
  use ExUnit.Case, async: true

  alias Forge.Ast.Heex

  defp sigil(source) do
    {:ok, ast, _comments} = Forge.Ast.from(source)

    {_ast, sigil} =
      Macro.prewalk(ast, nil, fn
        {:sigil_H, _, _} = sigil, nil -> {sigil, sigil}
        other, acc -> {other, acc}
      end)

    sigil
  end

  defp text_at(source, {line, column}, length) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1)
    |> String.slice(column - 1, length)
  end

  describe "scan/1" do
    test "finds interpolations in the body and in attributes" do
      assert {:ok, events} = Heex.scan(~S"<p class={@a}>{f(%{b: 1})}</p>")

      assert [
               {:interpolation, "@a", {1, 11}},
               {:interpolation, "f(%{b: 1})", {1, 16}}
             ] = events
    end

    test "skips braces in strings in interpolations" do
      assert {:ok, [{:interpolation, ~s[f("}")], {1, 2}}]} = Heex.scan(~s[{f("}")}])
    end

    test "finds EEx code at its first character" do
      assert {:ok, events} = Heex.scan("<%= for x <- xs do %>\n  {x}\n<% end %>")

      assert [
               {:start_expr, " for x <- xs do ", {1, 4}},
               {:interpolation, "x", {2, 4}},
               {:end_expr, " end ", {3, 3}}
             ] = events
    end

    test "ignores braces in comments and quoted attribute values" do
      assert {:ok, [{:interpolation, "x", {1, 30}}]} =
               Heex.scan(~s(<!-- {a} --> <a title="{b}">{x}</a>))
    end

    test "ignores braces in script and style tags" do
      assert {:ok, [{:interpolation, "x", {1, 50}}]} =
               Heex.scan("<script>if (x) { y() }</script><style>{}</style>{x}")
    end

    test "keeps skipping comments and attribute values across EEx tags" do
      assert {:ok,
              [{:expr, " a ", {1, 9}}, {:expr, " b ", {1, 32}}, {:interpolation, "c", {1, 43}}]} =
               Heex.scan(~s(<!-- <%= a %> {x} --><p id="<%= b %>{y}">{c}</p>))
    end

    test "fails on broken EEx" do
      assert :error = Heex.scan("<%= foo")
    end
  end

  describe "to_document/2" do
    test "maps positions in a heredoc" do
      source = ~S'''
      defmodule M do
        def render(assigns) do
          ~H"""
          <div>
            {button()}
          </div>
          """
        end
      end
      '''

      {:ok, template} = source |> sigil() |> Heex.template()
      {:ok, [{:interpolation, "button()", start}]} = Heex.scan(template.content)

      assert {5, 8} = position = Heex.to_document(template, start)
      assert "button()" = text_at(source, position, 8)
    end

    test "maps positions in a single line sigil" do
      source = ~S|def render(assigns), do: ~H"<b>{button()}</b>"|

      {:ok, template} = source |> sigil() |> Heex.template()
      {:ok, [{:interpolation, "button()", start}]} = Heex.scan(template.content)

      position = Heex.to_document(template, start)
      assert "button()" = text_at(source, position, 8)
    end
  end

  describe "document_code/2" do
    test "puts back the indentation of heredoc lines" do
      source = ~S'''
      def render(assigns) do
        ~H"""
        {f(
          x
        )}
        """
      end
      '''

      {:ok, template} = source |> sigil() |> Heex.template()
      {:ok, [{:interpolation, code, _start}]} = Heex.scan(template.content)

      assert "f(\n    x\n  )" = Heex.document_code(template, code)
    end
  end
end
