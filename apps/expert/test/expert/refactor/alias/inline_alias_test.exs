# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.InlineAliasTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Alias.InlineAlias

  test "inlines the selected alias usage" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
        # v
          Bar.bar()
        #   ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.Bar

        def foo() do
          Foo.Bar.bar()
        end
      end
      """
    )
  end

  test "inlines the selected alias with nested declaration" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias Foo.{
          Alpha,
          Qez.Za.{
            Delta,
            Bar
          }
        }

        def foo() do
        # v
          Bar.bar()
        #   ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.{
          Alpha,
          Qez.Za.{
            Delta,
            Bar
          }
        }

        def foo() do
          Foo.Qez.Za.Bar.bar()
        end
      end
      """
    )
  end

  test "inlines the last alias declaration" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias Foo.{
          Alpha,
          Qez.{
            Delta,
            Bar
          }
        }

        alias __MODULE__.Bar

        def foo() do
        # v
          Bar.bar()
        #   ^
        end
      end
      """,
      """
      defmodule Foo do
        alias Foo.{
          Alpha,
          Qez.{
            Delta,
            Bar
          }
        }

        alias __MODULE__.Bar

        def foo() do
          __MODULE__.Bar.bar()
        end
      end
      """
    )
  end

  test "inlines the renamed alias" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias __MODULE__.Foo2.Bar, as: B

        def foo() do
        # v
          B.bar()
        # ^
        end
      end
      """,
      """
      defmodule Foo do
        alias __MODULE__.Foo2.Bar, as: B

        def foo() do
          __MODULE__.Foo2.Bar.bar()
        end
      end
      """
    )
  end

  test "inlines selected alias with extra modules" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias __MODULE__.Bar

        def foo() do
        # v
          Bar.Qez.bar()
        #  #    ^
        end
      end
      """,
      """
      defmodule Foo do
        alias __MODULE__.Bar

        def foo() do
          __MODULE__.Bar.Qez.bar()
        end
      end
      """
    )
  end

  test "inlines partially selected alias" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Foo do
        alias __MODULE__.Bar

        def foo() do
        # v
          Bar.Qez.bar()
        #   ^
        end
      end
      """,
      """
      defmodule Foo do
        alias __MODULE__.Bar

        def foo() do
          __MODULE__.Bar.Qez.bar()
        end
      end
      """
    )
  end

  test "inlines nested namespace alias" do
    assert_refactored(
      InlineAlias,
      """
      defmodule Shop do
        alias Shop.{
          Cart,
          Inventory.{Item},
          Inventory
        }

        def restock(item_id, quantity) do
        # v
          Inventory.update_stock(item_id, quantity)
        #         ^
        end
      end
      """,
      """
      defmodule Shop do
        alias Shop.{
          Cart,
          Inventory.{Item},
          Inventory
        }

        def restock(item_id, quantity) do
          Shop.Inventory.update_stock(item_id, quantity)
        end
      end
      """
    )
  end

  test "ignores alias declaration" do
    assert_ignored(
      InlineAlias,
      """
      defmodule Foo do
        #     v
        alias Foo
        #       ^

        def foo() do
          Bar.bar()
        end
      end
      """
    )
  end

  test "ignores aliases without same module declaration" do
    assert_ignored(
      InlineAlias,
      """
      defmodule Foo do
        alias Foo
        alias Foo.Bar.Delta

        def foo() do
        # v
          Bar.bar()
        #   ^
        end
      end
      """
    )
  end
end
