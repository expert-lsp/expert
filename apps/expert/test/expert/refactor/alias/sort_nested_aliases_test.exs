# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.SortNestedAliasesTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Alias.SortNestedAliases

  test "sorts nested aliases alphabetically" do
    assert_refactored(
      SortNestedAliases,
      """
      #   v
      alias Foo.{
        B,
        C,
        A
      }
      """,
      """
      alias Foo.{
        A,
        B,
        C
      }
      """
    )
  end

  test "sorts nested aliases recursively" do
    assert_refactored(
      SortNestedAliases,
      """
      #   v
      alias Foo.{
        C,
        B.{
          E,
          F,
          D,
        },
        C.Bar,
        B,
        A.Foo.Delta,
        A.Foo,
        A
      }
      """,
      """
      alias Foo.{
        A,
        A.Foo,
        A.Foo.Delta,
        B,
        B.{
          D,
          E,
          F
        },
        C,
        C.Bar
      }
      """
    )
  end

  test "ignores alias without nesting" do
    assert_ignored(
      SortNestedAliases,
      """
      #   v
      alias Foo.Bar.Delta, as: K
      """
    )
  end

  test "ignores already sorted alias" do
    assert_ignored(
      SortNestedAliases,
      """
      #   v
      alias Foo.{
        A,
        B,
        C
      }
      """
    )
  end

  test "ignores selection on other line" do
    assert_ignored(
      SortNestedAliases,
      """
      alias Foo.{
      # v
        A,
        B,
        C
      }
      """
    )
  end
end
