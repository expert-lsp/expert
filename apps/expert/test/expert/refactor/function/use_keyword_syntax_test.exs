# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.UseKeywordSyntaxTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Function.UseKeywordSyntax

  test "refactors function with keyword syntax" do
    assert_refactored(
      UseKeywordSyntax,
      """
      defmodule Foo do
        def bar(arg) do
          arg
        end

        #      v
        def baz(arg1, arg2 \\\\ nil) do
          bar(arg1) + arg2
        end
      end
      """,
      """
      defmodule Foo do
        def bar(arg) do
          arg
        end

        def baz(arg1, arg2 \\\\ nil), do: bar(arg1) + arg2
      end
      """
    )
  end

  test "refactors function with zero arguments and no return " do
    assert_refactored(
      UseKeywordSyntax,
      """
      #    v
      def baz do
      end
      """,
      """
      def baz, do: nil
      """
    )
  end

  test "refactors function with single statement that spans several blocks" do
    assert_refactored(
      UseKeywordSyntax,
      """
      defmodule Foo do
        #    v
        def parse(%{"arg" => arg}) do
          {:ok, %{arg: arg}}
        end
      end
      """,
      """
      defmodule Foo do
        def parse(%{"arg" => arg}), do: {:ok, %{arg: arg}}
      end
      """
    )
  end

  test "refactors function with a single multiline map" do
    assert_refactored(
      UseKeywordSyntax,
      """
      #    v
      def baz do
        %{
          username: "gp-pereira",
          language: "pt-BR"
        }
       end
      """,
      """
      def baz,
        do: %{
          username: "gp-pereira",
          language: "pt-BR"
        }
      """
    )
  end

  test "refactors function with a list" do
    assert_refactored(
      UseKeywordSyntax,
      """
      #    v
      def baz do
        [
         :a,
         :b
        ]
      end
      """,
      """
      def baz,
        do: [
          :a,
          :b
        ]
      """
    )
  end

  test "refactors function with a number" do
    assert_refactored(
      UseKeywordSyntax,
      """
      #    v
      def baz do
        0
      end
      """,
      """
      def baz, do: 0
      """
    )
  end

  test "refactors private function" do
    assert_refactored(
      UseKeywordSyntax,
      """
      defmodule Foo do
        #      v
        defp baz(arg) do
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defp baz(arg), do: arg
      end
      """
    )
  end

  test "ignores multiple statements functions " do
    assert_ignored(
      UseKeywordSyntax,
      """
      defmodule Foo do
        #    v
        def baz(arg) do
          foo1(arg)
          foo2(arg)
          foo(arg)
        end
      end
      """
    )
  end

  test "ignores keyword functions" do
    assert_ignored(
      UseKeywordSyntax,
      """
      defmodule Foo do
        #     v
        def baz(arg1), do: arg1
      end
      """
    )
  end

  test "ignores functions outside range" do
    assert_ignored(
      UseKeywordSyntax,
      """
      #      v
      defmodule Foo do
        def bar(arg) do
          arg
        end

        def bar(arg) do
          arg
        end
      end
      """
    )
  end
end
