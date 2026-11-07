# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.MergeAliasesTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Alias.MergeAliases

  test "merges the selected aliases" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.K.Bar
        alias Qez.K.{Delta}
        alias Qez.K.Delta.Too.Foo
        alias Qez.K.Delta.Too.Bar.Foo
        alias Qez.K.Delta.Foo.{Y, J}
      #                            ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.K.{
          Bar,
          Delta,
          Delta.Foo.{
            J,
            Y
          },
          Delta.Too.{
            Foo,
            Bar.Foo
          }
        }
      end
      """
    )
  end

  test "merges the selected deeply nested aliases" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{Delta}
        alias Qez.Bar
        alias Qez.Delta.Foo
        alias Qez.Delta.Foo.Bar.K
      #                         ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Bar,
          Delta,
          Delta.{
            Foo,
            Foo.Bar.K
          }
        }
      end
      """
    )
  end

  test "merges two groups of selected aliases" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{Delta}
        alias Qez.Bar
        alias Delta.Foo
        alias Delta.Bar.Foo
      #                   ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Bar,
          Delta
        }

        alias Delta.{
          Foo,
          Bar.Foo
        }
      end
      """
    )
  end

  test "merges selected aliases without removing a direct alias" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Bar
        alias Bar.Foo
        alias Bar.Delta
      #               ^
      end
      """,
      """
      defmodule Foo do
        alias Bar

        alias Bar.{
          Delta,
          Foo
        }
      end
      """
    )
  end

  test "merges selected aliases without removing a renamed alias" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Bar.Alpha, as: A
        alias Bar.Foo
        alias Bar.Delta
      #               ^
      end
      """,
      """
      defmodule Foo do
        alias Bar.Alpha, as: A

        alias Bar.{
          Delta,
          Foo
        }
      end
      """
    )
  end

  test "merges the selected aliases even if separate by other code" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{Delta}

        import Foo

        def foo, do: :foo

        alias Qez.Bar
      #             ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Bar,
          Delta
        }

        import Foo

        def foo, do: :foo
      end
      """
    )
  end

  test "merges removes duplicated aliases" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{Delta}
        alias Qez.{Delta}
        alias Qez.{K}
      #             ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Delta,
          K
        }
      end
      """
    )
  end

  test "ignore already merged aliases" do
    assert_ignored(
      MergeAliases,
      """
      defmodule Foo do
      #           v
        alias Qez.{Delta, K}
      #                    ^
      end
      """
    )
  end

  test "merges selected alias with multiple newlines" do
    assert_refactored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{Delta}
        alias Qez.{K}
      #             ^

        def foo, do: 42
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Delta,
          K
        }

        def foo, do: 42
      end
      """
    )
  end

  test "ignores single alias" do
    assert_ignored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Bar.Foo
      #             ^
      end
      """
    )
  end

  test "ignores unmergeable aliases" do
    assert_ignored(
      MergeAliases,
      """
      defmodule Foo do
      # v
        alias Bar.Foo
        alias Qez.Delta
      #               ^
      end
      """
    )
  end

  test "ignores outside alias" do
    assert_ignored(
      MergeAliases,
      """
      defmodule Foo do
        def foo() do
          #    v
          Foo.{Bar}
          #      ^
        end
      end
      """
    )
  end

  test "ignores partially selected alias" do
    assert_ignored(
      MergeAliases,
      """
      defmodule Foo do
        # v
          alias Foo.{Bar.Foo}
          alias Foo.Bar.Delta.K
          alias Foo.Bar.Delta.F
        #                   ^
      end
      """
    )
  end
end
