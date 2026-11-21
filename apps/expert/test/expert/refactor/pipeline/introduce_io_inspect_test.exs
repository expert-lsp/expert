# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.IntroduceIOInspectTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Pipeline.IntroduceIOInspect

  test "introduces piped IO.inspect on the selected node" do
    assert_refactored(
      IntroduceIOInspect,
      """
      def foo(arg) do
      # v
        arg + 10
      #   ^
      end
      """,
      """
      def foo(arg) do
        (arg |> IO.inspect()) + 10
      end
      """
    )
  end

  test "ignores variable declarations" do
    assert_ignored(
      IntroduceIOInspect,
      """
      #                  v
      def foo(%{"arg" => arg}) when arg == 10 do
      #                    ^
        arg + 10
      end
      """
    )
  end

  test "ignores the whole anonymous function" do
    assert_ignored(
      IntroduceIOInspect,
      """
      foo
      #       v
      |> then(&bar(&1))
      #              ^
      """
    )
  end

  test "ignores part of constant" do
    assert_ignored(
      IntroduceIOInspect,
      """
      def foo() do
      #  v
        @foo
      #    ^
      end
      """
    )
  end

  test "ignores a whole with clause" do
    assert_ignored(
      IntroduceIOInspect,
      """
      #    v
      with {:ok, arg} <- foo(arg) do
      #                         ^
        arg
      end
      """
    )
  end

  test "ignores alias" do
    assert_ignored(
      IntroduceIOInspect,
      """
      defmodule Foo do
      # v
        alias Foo.Bar
      #             ^
      end
      """
    )
  end

  test "ignores part of pipeline" do
    assert_ignored(
      IntroduceIOInspect,
      """
      defmodule Foo do
        def foo() do
          arg
          #  v
          |> qez()
          #      ^
          |> bar()
        end
      end
      """
    )
  end
end
