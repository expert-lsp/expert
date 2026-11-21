# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.ExtractAliasTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Alias.ExtractAlias

  test "extracts the selected alias and declare it on top" do
    assert_refactored(
      ExtractAlias,
      """
      defmodule Foo do
        def foo() do
        # v
          Foo.Bar.bar()
        #       ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
          Bar.bar()
        end
      end
      """
    )
  end

  test "extracts the partially selected alias and declare it on top" do
    assert_refactored(
      ExtractAlias,
      """
      defmodule Foo do
        def foo() do
        # v
          Foo.Bar.Delta.bar()
        #       ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
          Bar.Delta.bar()
        end
      end
      """
    )
  end

  test "extracts the selected alias but does not redeclare it" do
    assert_refactored(
      ExtractAlias,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
        # v
          Foo.Bar.bar()
        #       ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
          Bar.bar()
        end
      end
      """
    )
  end

  test "extracts the selected alias and declare it after others aliases" do
    assert_refactored(
      ExtractAlias,
      """
      defmodule Foo do
        alias Foo.Delta

        alias Delta.{
          Qez
        }

        def foo() do
        # v
          Foo.Bar.bar()
        #       ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.Delta

        alias Delta.{
          Qez
        }

        alias Foo.Bar

        def foo() do
          Bar.bar()
        end
      end
      """
    )
  end

  test "ignores alias declaration" do
    assert_ignored(
      ExtractAlias,
      """
      defmodule Foo do
        #     v
        alias Foo.Bar
        #           ^
      end
      """
    )
  end

  test "ignores single alias" do
    assert_ignored(
      ExtractAlias,
      """
      defmodule Foo do
        def foo() do
        # v
          Foo
        #   ^
        end
      end
      """
    )
  end

  test "ignores if there would be a name conflict" do
    assert_ignored(
      ExtractAlias,
      """
      defmodule Foo do
        alias Qez.Bar

        def foo() do
        # v
          Foo.Bar
        #       ^
        end
      end
      """
    )
  end

  test "ignores outside module" do
    assert_ignored(
      ExtractAlias,
      """
      def foo() do
      # v
        Foo.Bar.bar()
      #       ^
      end
      """
    )
  end
end
