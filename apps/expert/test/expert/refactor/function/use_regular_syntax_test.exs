# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.UseRegularSyntaxTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Function.UseRegularSyntax

  test "refactors keyword function with regular syntax" do
    assert_refactored(
      UseRegularSyntax,
      """
      defmodule Foo do
        #      v
        def baz(arg1, arg2 \\\\ nil), do: bar(arg1) + arg2
      end
      """,
      """
      defmodule Foo do
        def baz(arg1, arg2 \\\\ nil) do
          bar(arg1) + arg2
        end
      end
      """
    )
  end

  test "refactors function with zero arguments and no return " do
    assert_refactored(
      UseRegularSyntax,
      """
      defmodule Foo do
        #      v
        def baz, do: nil
      end
      """,
      """
      defmodule Foo do
        def baz do
          nil
        end
      end
      """
    )
  end

  test "refactors private function" do
    assert_refactored(
      UseRegularSyntax,
      """
      defmodule Foo do
        #      v
        defp baz, do: nil
      end
      """,
      """
      defmodule Foo do
        defp baz do
          nil
        end
      end
      """
    )
  end

  test "ignores regular functions" do
    assert_ignored(
      UseRegularSyntax,
      """
      defmodule Foo do
        #     v
        def baz(arg1) do
          arg1
        end
      end
      """
    )
  end

  test "ignores function declarations without a body" do
    assert_ignored(
      UseRegularSyntax,
      """
      defmodule Foo do
        #       v
        defp some_function(arg1, opts \\\\ [])
      end
      """
    )
  end

  test "ignores functions outside range" do
    assert_ignored(
      UseRegularSyntax,
      """
      defmodule Foo do
        def bar(arg), do: arg

        def baz(arg),
          do: %{
            username: "gp-pereira",
            language: "pt-BR"
          }

        # v
      end
      """
    )
  end
end
