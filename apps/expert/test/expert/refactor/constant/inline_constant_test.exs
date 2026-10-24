# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Constant.InlineConstantTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Constant.InlineConstant

  test "inlines the selected constant usage" do
    assert_refactored(
      InlineConstant,
      """
      defmodule Foo do
        @foo 42

        def foo(bar \\\\ @foo) do
        # v
          @foo + bar
        #    ^
        end
      end
      """,
      """
      defmodule Foo do
        @foo 42

        def foo(bar \\\\ @foo) do
          42 + bar
        end
      end
      """
    )
  end

  test "inlines the single usage" do
    assert_refactored(
      InlineConstant,
      """
      defmodule Foo do
        @foo %{test: 1}

        def foo(bar) do
        #   v
          %{@foo | test: bar}
        #      ^
        end
      end
      """,
      """
      defmodule Foo do
        @foo %{test: 1}

        def foo(bar) do
          %{%{test: 1} | test: bar}
        end
      end
      """
    )
  end

  test "ignores the constant definition" do
    assert_ignored(
      InlineConstant,
      """
      defmodule Foo do
      # v
        @foo 42
      #    ^

        def foo(bar \\\\ @foo) do
          @foo + bar
        end
      end
      """
    )
  end

  test "ignores constant without a previous definition" do
    assert_ignored(
      InlineConstant,
      """
      defmodule Foo do
        def foo(bar \\\\ @foo) do
        #  v
          @foo + bar
        #    ^
        end
      end
      """
    )
  end
end
