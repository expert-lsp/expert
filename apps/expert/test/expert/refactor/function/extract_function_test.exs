# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.ExtractFunctionTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Function.ExtractFunction

  test "extracts selection into a private function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
      #   v
          a
          |> bar()
          |> baz(b)
      #           ^
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          extracted_function(
            a,
            b
          )
        end

        defp extracted_function(a, b) do
          a
          |> bar()
          |> baz(b)
        end
      end
      """
    )
  end

  test "extracts function using a new unique name" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a) do
      #   v
          a
          |> bar()
      #          ^
        end

        def extracted_function(_), do: 1
        def extracted_function1(_), do: 2
      end
      """,
      """
      defmodule Foo do
        def foo(a) do
          extracted_function2(a)
        end

        def extracted_function(_), do: 1
        def extracted_function1(_), do: 2

        defp extracted_function2(a) do
          a
          |> bar()
        end
      end
      """
    )
  end

  test "extracts function when module has a bodyless function declaration" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        defp some_function(arg1, opts \\\\ %{key1: "value1", key2: true})

        def other do
      #   v
          42
      #    ^
        end
      end
      """,
      """
      defmodule Foo do
        defp some_function(arg1, opts \\\\ %{key1: "value1", key2: true})

        def other do
          extracted_function()
        end

        defp extracted_function() do
          42
        end
      end
      """
    )
  end

  test "extracts head of a pipeline into function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
        # v
          a
        # ^
          |> foo(b)
          |> bar()
          |> qez(b)
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          extracted_function(a)
          |> foo(b)
          |> bar()
          |> qez(b)
        end

        defp extracted_function(a) do
          a
        end
      end
      """
    )
  end

  test "extracts beginning of a pipeline into function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
        # v
          a
          |> foo(b)
        #         ^
          |> bar()
          |> qez(b)
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          extracted_function(
            a,
            b
          )
          |> bar()
          |> qez(b)
        end

        defp extracted_function(a, b) do
          a
          |> foo(b)
        end
      end
      """
    )
  end

  test "extracts middle of a pipeline into function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
          a
          |> foo()
          #  v
          |> bar(b)
          |> quack(b)
          |> qez()
        #        ^
          |> baz()
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          a
          |> foo()
          |> extracted_function(b)
          |> baz()
        end

        defp extracted_function(arg1, b) do
          arg1
          |> bar(b)
          |> quack(b)
          |> qez()
        end
      end
      """
    )
  end

  test "extracts middle to end of a pipeline into function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
          a
          |> foo()
          |> bar(b)
          #  v
          |> quack(b)
          |> qez()
          |> baz()
          #      ^
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          a |> foo() |> bar(b) |> extracted_function(b)
        end

        defp extracted_function(arg1, b) do
          arg1
          |> quack(b)
          |> qez()
          |> baz()
        end
      end
      """
    )
  end

  test "extracts end of a pipeline into function" do
    assert_refactored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(a, b) do
          a
          |> foo()
          |> bar(b)
          #  v
          |> qez(b)
          #       ^
        end
      end
      """,
      """
      defmodule Foo do
        def foo(a, b) do
          a
          |> foo()
          |> bar(b)
          |> extracted_function(b)
        end

        defp extracted_function(arg1, b) do
          arg1 |> qez(b)
        end
      end
      """
    )
  end

  test "ignore with clauses" do
    assert_ignored(
      ExtractFunction,
      """
      defmodule Foo do
        def foo(arg) do
          #    v
          with {:ok, arg} <- format(arg) do
          #                            ^
            {:ok, arg}
          end
        end
      end
      """
    )
  end

  test "ignore module constants" do
    assert_ignored(
      ExtractFunction,
      """
      defmodule Foo do
        @bar 42

        def foo(arg) do
        # v
          @bar
        #    ^
        end
      end
      """
    )
  end

  test "ignore anonymous functions" do
    assert_ignored(
      ExtractFunction,
      """
      defmodule Foo do
        @bar 42

        def foo(arg) do
        #               v
          Enum.map(arg, &(&1 + 1))
        #                       ^
        end
      end
      """
    )
  end

  test "ignore variable declaration functions" do
    assert_ignored(
      ExtractFunction,
      """
      defmodule Foo do
        @bar 42

        #       v
        def foo(arg) do
        #         ^
          Enum.map(arg, &(&1 + 1))
        end
      end
      """
    )
  end

  test "ignores alias" do
    assert_ignored(
      ExtractFunction,
      """
      defmodule Foo do
      # v
        alias Foo.Bar
      #             ^
      end
      """
    )
  end

  test "ignores selection outside module" do
    assert_ignored(
      ExtractFunction,
      """
      def foo() do
      # v
        :outside
      #        ^
      end
      """
    )
  end
end
