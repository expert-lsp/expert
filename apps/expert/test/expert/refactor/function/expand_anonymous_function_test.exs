# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.ExpandAnonymousFunctionTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Function.ExpandAnonymousFunction

  test "expands anonymous function from & to fn syntax" do
    assert_refactored(
      ExpandAnonymousFunction,
      """
      filenames
      #           v
      |> Enum.map(&File.read!(&1))
      #                         ^
      """,
      """
      filenames
      |> Enum.map(fn arg1 -> File.read!(arg1) end)
      """
    )
  end

  test "expands anonymous function with &/args to fn syntax" do
    assert_refactored(
      ExpandAnonymousFunction,
      """
      filenames
      #              v
      |> Enum.reduce(&Reader.read/2)
      #                           ^
      """,
      """
      filenames
      |> Enum.reduce(fn arg1, arg2 -> Reader.read(arg1, arg2) end)
      """
    )
  end

  test "expands anonymous function with multiple usages of same arg" do
    assert_refactored(
      ExpandAnonymousFunction,
      """
      def foo(modules) do
        modules
        #             v
        |> Stream.map(&{&1, &1.available?(zipper)})
        #                                        ^
      end
      """,
      """
       def foo(modules) do
        modules
        |> Stream.map(fn arg1 -> {arg1, arg1.available?(zipper)} end)
      end
      """
    )
  end

  test "expands anonymous function with zero arguments" do
    assert_refactored(
      ExpandAnonymousFunction,
      """
      #     v
      query(&connection/0)
      #                 ^
      """,
      """
      query(fn -> connection() end)
      """
    )
  end

  test "ignores capture variables" do
    assert_ignored(
      ExpandAnonymousFunction,
      """
      def foo(modules) do
        modules
        #                   v
        |> Stream.map(&{&1, &1.available?(zipper)})
        #                    ^
      end
      """
    )
  end
end
