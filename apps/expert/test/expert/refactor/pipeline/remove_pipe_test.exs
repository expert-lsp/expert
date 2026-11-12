# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.RemovePipeTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Pipeline.RemovePipe

  test "removes pipe operator" do
    assert_refactored(
      RemovePipe,
      """
      #        v
      arg1 |> foo(arg2)
      """,
      """
      foo(arg1, arg2)
      """
    )
  end

  test "removes pipe operator from start of pipeline" do
    assert_refactored(
      RemovePipe,
      """
      arg1
      #  v
      |> foo(arg2)
      |> bar()
      """,
      """
      foo(
        arg1,
        arg2
      )
      |> bar()
      """
    )
  end

  test "removes pipe operator from middle of pipeline" do
    assert_refactored(
      RemovePipe,
      """
      arg1
      |> bar()
      #  v
      |> foo(arg2)
      |> bar()
      """,
      """
      foo(
        arg1
        |> bar(),
        arg2
      )
      |> bar()
      """
    )
  end

  test "removes pipe operator from end of pipeline" do
    assert_refactored(
      RemovePipe,
      """
      arg1
      |> bar()
      |> foo(arg2)
      #  v
      |> bar()
      """,
      """
      bar(
        arg1
        |> bar()
        |> foo(arg2)
      )
      """
    )
  end

  test "removes pipe into parenless call" do
    assert_refactored(
      RemovePipe,
      """
      #       v
      arg1 |> foo
      """,
      """
      foo(arg1)
      """
    )
  end

  test "ignores range without pipes" do
    assert_ignored(
      RemovePipe,
      """
      def foo(arg1) do
        # v
        foo(arg1, 10)
      end
      """
    )
  end

  test "ignores range outside pipe usage" do
    assert_ignored(
      RemovePipe,
      """
      # v
      def foo(arg1) do
        arg1 |> foo(@arg2)
      end
      """
    )
  end
end
