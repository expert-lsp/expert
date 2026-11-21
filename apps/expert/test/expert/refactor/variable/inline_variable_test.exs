# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Variable.InlineVariableTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Variable.InlineVariable

  test "inlines the all usages of the selected variable and remove it" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #   v
          sum = arg + 4
      #     ^
          arg * sum
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          arg * (arg + 4)
        end
      end
      """
    )
  end

  test "inlines the all usages until a new assignment" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #   v
          sum = arg + 4
      #     ^
          bar =
            case arg * sum do
              40 ->
                arg2 = arg - sum
                [%{sum: sum}] = [%{sum: arg2 + 10 - sum}]
                arg * sum

              30 ->
                sum
            end

          bar + sum
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          bar =
            case arg * (arg + 4) do
              40 ->
                arg2 = arg - (arg + 4)
                [%{sum: sum}] = [%{sum: arg2 + 10 - (arg + 4)}]
                arg * sum

              30 ->
                arg + 4
            end

          bar + (arg + 4)
        end
      end
      """
    )
  end

  test "removes the assignment but keep value in block return" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
          arg2 = arg - 1
      #   v
          sum = arg2 + 10
      #     ^
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          arg2 = arg - 1
          arg2 + 10
        end
      end
      """
    )
  end

  test "removes the assignment but keep value in single statement block return" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #   v
          sum = arg2 + 10
      #     ^
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          arg2 + 10
        end
      end
      """
    )
  end

  test "removes the assignment but keep value in CASE condition" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #        v
          case sum = arg + 10 do
      #          ^
            10 -> sum + 10
            sum -> sum + 12
          end
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          case arg + 10 do
            10 -> arg + 10 + 10
            sum -> sum + 12
          end
        end
      end
      """
    )
  end

  test "removes the assignment but keep value in IF condition" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #      v
          if sum = arg + 10 do
      #        ^
            sum = sum * 4
            sum * 8
          else
            sum - 10
          end
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          if arg + 10 do
            sum = (arg + 10) * 4
            sum * 8
          else
            arg + 10 - 10
          end
        end
      end
      """
    )
  end

  test "removes the assignment but keep value in single CASE clause block" do
    assert_refactored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
          case arg * sum do
            40 ->
          #   v
              sum = arg2 + 10
          #     ^

            30 ->
              sum
          end
        end
      end
      """,
      """
      defmodule Foo do
        def foo(arg) do
          case arg * sum do
            40 ->
              arg2 + 10

            30 ->
              sum
          end
        end
      end
      """
    )
  end

  test "ignore assignment inside other assignment" do
    assert_ignored(
      InlineVariable,
      """
      defmodule Foo do
        def foo(arg) do
      #           v
          c = a = b = d = arg + 10
      #           ^
          b + a
        end
      end
      """
    )
  end

  test "ignores function args" do
    assert_ignored(
      InlineVariable,
      """
       defmodule Foo do
        #       v
        def foo(arg) do
        #         ^
          arg
        end
      end
      """
    )
  end

  test "ignores variable declaration" do
    assert_ignored(
      InlineVariable,
      """
       defmodule Foo do
        def foo(arg) do
        # v
          %{bar: bar} = arg
        #           ^
        end
      end
      """
    )
  end
end
