defmodule Expert.Provider.Handlers.CodeFoldingTest do
  use ExUnit.Case, async: true

  alias Expert.Document.Context
  alias Expert.Provider.Handlers.CodeFolding
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentFoldingRange
  alias GenLSP.Structures.FoldingRange
  alias GenLSP.Structures.FoldingRangeParams
  alias GenLSP.Structures.TextDocumentIdentifier

  defp fold(source) do
    source
    |> fold_in_order()
    |> Enum.sort_by(&{&1.start_line, &1.end_line})
  end

  defp fold_in_order(source) do
    uri = "file:///fold_test.ex"
    document = Document.new(uri, source, 1)

    request = %TextDocumentFoldingRange{
      id: 1,
      params: %FoldingRangeParams{
        text_document: %TextDocumentIdentifier{uri: uri}
      }
    }

    context = %Context{uri: uri, document: document, project: nil}

    {:ok, ranges} = CodeFolding.handle(request, context)
    ranges
  end

  defp range(start_line, end_line) do
    %FoldingRange{start_line: start_line, end_line: end_line}
  end

  defp comment_range(start_line, end_line) do
    %FoldingRange{start_line: start_line, end_line: end_line, kind: "comment"}
  end

  test "preserves block, string, and comment ordering in mixed documents" do
    source = ~S'''
    defmodule Mixed do
      @moduledoc """
      Module docs.
      More docs.
      """
      # first
      # second
      def run do
        callback = fn ->
          ~s"""
          first
          second
          """
        end
        callback.()
      end
    end
    '''

    assert fold_in_order(source) == [
             range(8, 12),
             range(7, 14),
             range(0, 15),
             range(9, 11),
             range(1, 3),
             comment_range(5, 6)
           ]
  end

  describe "do/end blocks" do
    test "folds a multi-line module" do
      source = """
      defmodule Foo do
        :ok
      end
      """

      assert fold(source) == [range(0, 1)]
    end

    test "folds nested function inside a module" do
      source = """
      defmodule Foo do
        def bar do
          :ok
        end
      end
      """

      assert fold(source) == [range(0, 3), range(1, 2)]
    end

    test "folds if/else, case, with, and other do/end constructs" do
      source = """
      defmodule Foo do
        def bar(x) do
          if x do
            :a
          else
            :b
          end

          case x do
            :a -> :ok
            _ -> :err
          end

          with {:ok, v} <- {:ok, x} do
            v
          end
        end
      end
      """

      ranges = fold(source)

      assert range(0, 16) in ranges
      assert range(1, 15) in ranges
      assert range(2, 5) in ranges
      assert range(8, 10) in ranges
      assert range(13, 14) in ranges
    end

    test "does not fold a single-line do/end" do
      assert fold("def foo, do: :ok\n") == []
    end

    test "does not fold an empty body" do
      source = """
      defmodule Foo do
      end
      """

      assert fold(source) == []
    end
  end

  describe "anonymous functions" do
    test "folds a multi-line anonymous function" do
      source = """
      callback = fn value ->
        value + 1
      end
      """

      assert fold(source) == [range(0, 1)]
    end

    test "folds nested anonymous functions" do
      source = """
      outer = fn value ->
        inner = fn ->
          value
        end
        inner.()
      end
      """

      assert fold(source) == [range(0, 4), range(1, 2)]
    end

    test "folds a multi-clause anonymous function" do
      source = """
      formatter = fn
        :ok ->
          "ok"
        :error ->
          "error"
      end
      """

      assert fold(source) == [range(0, 4)]
    end

    test "does not fold a single-line anonymous function" do
      assert fold("callback = fn value -> value end\n") == []
    end
  end

  describe "heredocs" do
    test "folds a multi-line @moduledoc heredoc" do
      source = """
      defmodule Foo do
        @moduledoc \"\"\"
        Line one.
        Line two.
        \"\"\"
      end
      """

      ranges = fold(source)

      assert range(0, 4) in ranges
      assert range(1, 3) in ranges
    end

    test "folds a multi-line @doc heredoc" do
      source = """
      defmodule Foo do
        @doc \"\"\"
        Function doc.
        More content.
        \"\"\"
        def bar, do: :ok
      end
      """

      assert range(1, 3) in fold(source)
    end

    test "folds an inline heredoc string" do
      source = """
      defmodule Foo do
        def bar do
          \"\"\"
          a
          b
          \"\"\"
        end
      end
      """

      assert range(2, 4) in fold(source)
    end

    test "folds a function with inline heredoc string" do
      source = """
      defmodule Foo do
        def bar do
          \"\"\"
          a
          b
          \"\"\"
        end
      end
      """

      assert range(1, 5) in fold(source)
    end

    test "does not fold a 2-line heredoc with empty content" do
      source = """
      defmodule Foo do
        @moduledoc \"\"\"
        \"\"\"
      end
      """

      ranges = fold(source)

      refute Enum.any?(ranges, fn r -> r.start_line == 1 end)
    end
  end

  describe "multi-line plain strings" do
    test "folds a string spanning multiple lines" do
      source = """
      defmodule Foo do
        def bar do
          "line1
          line2
          line3"
        end
      end
      """

      assert range(2, 3) in fold(source)
    end
  end

  describe "sigils" do
    test "folds a multiline sigil" do
      source = """
      defmodule Foo do
        def bar do
          ~H\"\"\"
          a
          b
          \"\"\"
        end
      end
      """

      assert range(2, 4) in fold(source)
    end

    test "folds a function with a multiline sigil" do
      source = """
      defmodule Foo do
        def bar do
          ~H\"\"\"
          a
          b
          \"\"\"
        end
      end
      """

      assert range(1, 5) in fold(source)
    end
  end

  describe "comments" do
    test "folds two or more consecutive comment lines" do
      source = """
      # one
      # two
      # three
      :ok
      """

      assert comment_range(0, 2) in fold(source)
    end

    test "folds a pair of consecutive comment lines" do
      source = """
      # one
      # two
      :ok
      """

      assert comment_range(0, 1) in fold(source)
    end

    test "does not fold a single comment line" do
      source = """
      # lonely
      :ok
      """

      refute Enum.any?(fold(source), fn r -> r.kind == "comment" end)
    end

    test "does not fold across a blank line between comments" do
      source = """
      # one
      # two

      # three
      # four
      :ok
      """

      ranges = fold(source)

      assert comment_range(0, 1) in ranges
      assert comment_range(3, 4) in ranges
    end

    test "does not group a comment broken by a line of code" do
      source = """
      # one
      x = 1
      # two
      :ok
      """

      refute Enum.any?(fold(source), fn r -> r.kind == "comment" end)
    end

    test "does not start a comment fold from a trailing comment" do
      source = """
      x = 1 # trailing
      # standalone one
      # standalone two
      :ok
      """

      ranges = fold(source)

      assert comment_range(1, 2) in ranges
      refute comment_range(0, 2) in ranges
    end

    test "folds comments indented inside a block" do
      source = """
      defmodule Foo do
        def bar do
          # step one
          # step two
          :ok
        end
      end
      """

      assert comment_range(2, 3) in fold(source)
    end
  end

  describe "invalid input" do
    test "returns an empty list for syntactically invalid documents" do
      assert fold("defmodule Foo do def bar(\n") == []
    end
  end
end
