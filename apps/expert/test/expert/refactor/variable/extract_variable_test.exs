# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Variable.ExtractVariableTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Variable.ExtractVariable

  test "extracts the selection into a variable" do
    assert_refactored(
      ExtractVariable,
      """
      arg = 10
      #   v
      foo(arg.test)
      #          ^
      """,
      """
      arg = 10
      extracted_variable = arg.test
      foo(extracted_variable)
      """
    )
  end

  test "extracts a variable using an unique name" do
    assert_refactored(
      ExtractVariable,
      """
      def available_refactorings(zipper, selection_or_line, modules) do
        modules
        |> Stream.map(fn arg1 ->
          extracted_variable = zipper
          extracted_variable4 = extracted_variable
          extracted_variable2 = extracted_variable4
          extracted_variable3 = extracted_variable2
      #                                               v
          {arg1, arg1.available?(extracted_variable3, selection_or_line)}
      #                                                               ^
        end)
      end
      """,
      """
      def available_refactorings(zipper, selection_or_line, modules) do
        modules
        |> Stream.map(fn arg1 ->
          extracted_variable = zipper
          extracted_variable4 = extracted_variable
          extracted_variable2 = extracted_variable4
          extracted_variable3 = extracted_variable2
          extracted_variable5 = selection_or_line
          {arg1, arg1.available?(extracted_variable3, extracted_variable5)}
        end)
      end
      """
    )
  end

  test "extracts variable inside single statement anonymous function" do
    assert_refactored(
      ExtractVariable,
      """
      def foo(arg) do
        arg
        #                     v
        |> Enum.map(fn arg -> arg + 10 end)
        #                       ^
      end
      """,
      """
      def foo(arg) do
        arg
        |> Enum.map(fn arg ->
          extracted_variable = arg
          extracted_variable + 10
        end)
      end
      """
    )
  end

  test "extracts variable inside multiple statements anonymous function" do
    assert_refactored(
      ExtractVariable,
      """
      def foo(arg) do
        arg
        |> Enum.map(fn arg ->
          arg = arg + 10
          #     v
          arg = arg + 20
          #       ^
        end)
      end
      """,
      """
      def foo(arg) do
        arg
        |> Enum.map(fn arg ->
          arg = arg + 10
          extracted_variable = arg
          arg = extracted_variable + 20
        end)
      end
      """
    )
  end

  test "extracts variable inside single statement function" do
    assert_refactored(
      ExtractVariable,
      """
      def foo(arg) do
      #       v
        arg + 20
      #        ^
      end
      """,
      """
      def foo(arg) do
        extracted_variable = 20
        arg + extracted_variable
      end
      """
    )
  end

  test "extracts variable inside COND clause" do
    assert_refactored(
      ExtractVariable,
      """
      def foo(arg) do
        cond do
      #   v
          arg + 10 < 50 ->
      #          ^
            arg

          true ->
            false
        end
      end
      """,
      """
      def foo(arg) do
        extracted_variable = arg + 10

        cond do
          extracted_variable < 50 ->
            arg

          true ->
            false
        end
      end
      """
    )
  end

  test "expands anonymous function before extracting variable" do
    assert_refactored(
      ExtractVariable,
      """
      def foo(module) do
        modules
        #                   v
        |> Stream.map(&{&1, &1.available?(zipper, selection_or_line)})
        #                                                          ^
      end
      """,
      """
       def foo(module) do
        modules
        |> Stream.map(fn arg1 ->
          extracted_variable = arg1.available?(zipper, selection_or_line)
          {arg1, extracted_variable}
        end)
      end
      """
    )
  end

  test "rewrites function using keyword syntax before extracting variable" do
    assert_refactored(
      ExtractVariable,
      """
      #                                     v
      def foo(arg) when arg < 20, do: arg + 10
      #                                      ^
      """,
      """
      def foo(arg) when arg < 20 do
        extracted_variable = 10
        arg + extracted_variable
      end
      """
    )
  end

  test "rewrites if else using keyword syntax before extracting variable" do
    assert_refactored(
      ExtractVariable,
      """
      #                                      v
      if foo(arg), do: arg + 10, else: arg + 20
      #                                       ^
      """,
      """
      if foo(arg) do
        arg + 10
      else
        extracted_variable = 20
        arg + extracted_variable
      end
      """
    )
  end

  test "extracts from the correct branch after rewriting identical keyword if else branches" do
    assert_refactored(
      ExtractVariable,
      """
      #                                v
      if foo(arg), do: arg + 10, else: arg + 10
      #                                       ^
      """,
      """
      if foo(arg) do
        arg + 10
      else
        extracted_variable = arg + 10
        extracted_variable
      end
      """
    )
  end

  test "extracts variable that is the whole block" do
    assert_refactored(
      ExtractVariable,
      """
      cond do
        true ->
        # v
          arg
        #   ^

        _ ->
          arg + 10
      end
      """,
      """
      cond do
        true ->
          extracted_variable = arg
          extracted_variable

        _ ->
          arg + 10
      end
      """
    )
  end

  test "extracts variable that is inside whole block tuple" do
    assert_refactored(
      ExtractVariable,
      """
      with {:ok, zipper, selection_or_line} <- Parser.parse_inputs(original, range) do
        {
          :ok,
        # v
          zipper
        #      ^
          |> Refactor.available_refactorings(selection_or_line)
          |> Response.suggest_refactorings(uri, range)
        }
      end
      """,
      """
       with {:ok, zipper, selection_or_line} <- Parser.parse_inputs(original, range) do
        extracted_variable = zipper

        {
          :ok,
          extracted_variable
          |> Refactor.available_refactorings(selection_or_line)
          |> Response.suggest_refactorings(uri, range)
        }
      end
      """
    )
  end

  test "extracts single captured variable inside anonymous function" do
    assert_refactored(
      ExtractVariable,
      """
      def foo() do
        #                v
        Enum.map(1..2, &(&1))
        #                 ^
      end
      """,
      """
      def foo() do
        Enum.map(1..2, fn arg1 ->
          extracted_variable = arg1
          extracted_variable
        end)
      end
      """
    )
  end

  test "ignores function names inside captured function shorthand" do
    assert_ignored(
      ExtractVariable,
      """
      defmodule Foo do
        def all_atoms?(list) do
          #                v
          Enum.all?(list, &is_atom/1)
          #                      ^
        end
      end
      """
    )
  end

  test "ignores arity inside captured function shorthand" do
    assert_ignored(
      ExtractVariable,
      """
      defmodule Foo do
        def all_atoms?(list) do
          #                        v
          Enum.all?(list, &is_atom/1)
          #                        ^
        end
      end
      """
    )
  end

  test "ignores variable declarations" do
    assert_ignored(
      ExtractVariable,
      """
      quote do
      # v
        arg = 10
      #   ^
        foo(arg.test)
      end
      """
    )
  end

  test "ignores part of pipeline" do
    assert_ignored(
      ExtractVariable,
      """
      quote do
        zipper
        #  v
        |> module.execute(selection_or_line)
        #                                  ^
        |> module.refactoring()
      end
      """
    )
  end

  test "ignores part of constant" do
    assert_ignored(
      ExtractVariable,
      """
      def foo() do
      #  v
        @foo
      #    ^
      end
      """
    )
  end

  test "ignores alias" do
    assert_ignored(
      ExtractVariable,
      """
      defmodule Foo do
      # v
        alias Foo.Bar
      #             ^
      end
      """
    )

    assert_ignored(
      ExtractVariable,
      """
      defmodule Foo do
        def foo() do
      #   v
          Foo.Bar
      #         ^
        end
      end
      """
    )
  end
end
