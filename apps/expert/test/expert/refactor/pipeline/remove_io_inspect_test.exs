# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.RemoveIOInspectTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Pipeline.RemoveIOInspect

  test "removes the IO.inspect function call" do
    assert_refactored(
      RemoveIOInspect,
      """
      #        v
      IO.inspect(foo)
      """,
      """
      foo
      """
    )
  end

  test "removes IO.inspect function call with opts" do
    assert_refactored(
      RemoveIOInspect,
      """
      #        v
      IO.inspect(foo, opts: "foo: ")
      """,
      """
      foo
      """
    )
  end

  test "removes piped IO.inspect function call" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      #        v
      |> IO.inspect()
      """,
      """
      foo
      """
    )
  end

  test "removes piped IO.inspect function call with opts" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      #        v
      |> IO.inspect(label: "foo")
      """,
      """
      foo
      """
    )
  end

  test "removes piped IO.inspect function call in the middle of pipeline" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      |> baz()
      #        v
      |> IO.inspect()
      |> bar()
      """,
      """
      foo
      |> baz()
      |> bar()
      """
    )
  end

  test "removes piped IO.inspect function call in the middle of pipeline with opts" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      |> baz()
      #        v
      |> IO.inspect(label: "foo")
      |> bar()
      """,
      """
      foo
      |> baz()
      |> bar()
      """
    )
  end

  test "removes IO.inspect from anonymous function" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      #        v
      |> then(&IO.inspect(baz(&1, 40)))
      |> bar()
      """,
      """
      foo
      |> then(&baz(&1, 40))
      |> bar()
      """
    )
  end

  test "removes IO.inspect from anonymous function with opts" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      #        v
      |> then(&IO.inspect(baz(&1, 40), label: "baz(foo)"))
      |> bar()
      """,
      """
      foo
      |> then(&baz(&1, 40))
      |> bar()
      """
    )
  end

  test "removes IO.inspect from anonymous function with arity syntax" do
    assert_refactored(
      RemoveIOInspect,
      """
      foo
      #        v
      |> then(&IO.inspect/1)
      |> bar()
      """,
      """
      foo
      |> then(& &1)
      |> bar()
      """
    )
  end

  test "removes IO.inspect from block" do
    assert_refactored(
      RemoveIOInspect,
      """
      case arg do
        %{node: {:->, _, [args, _]}} = zipper ->
          # v
          IO.inspect("hello")

          if was_variable_used?(args, name),
            do: {:skip, zipper},
            else: {:cont, zipper}
      end
      """,
      """
          case arg do
        %{node: {:->, _, [args, _]}} = zipper ->
          "hello"

          if was_variable_used?(args, name),
            do: {:skip, zipper},
            else: {:cont, zipper}
      end
      """
    )
  end
end
