# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Forge.Refactor.Alias.ExpandAliasesTest do
  use Forge.Test.RefactorCase

  alias Forge.Refactor.Alias.ExpandAliases

  test "ignores already expanded aliases and their selected module names" do
    for {target, options} <- [
          {"Foo.Bar", ""},
          {"Foo.Bar", ", as: Baz"},
          {"__MODULE__.Bar", ""},
          {":lists", ", as: Lists"}
        ] do
      declaration = "alias #{target}#{options}"
      zipper = text_to_zipper("defmodule Example do\n  #{declaration}\nend")

      for {text, column} <- [{declaration, 3}, {target, 9}] do
        selection = Sourceror.parse_string!(text, line: 2, column: column)

        assert Forge.Refactor.list(zipper, selection, [ExpandAliases]) == []
        assert Forge.Refactor.execute(zipper, selection, ExpandAliases) == :error
      end
    end
  end

  test "expands grouped aliases after an already expanded alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        alias Qez.Alpha
      # v
        alias Qez.{Bar, Delta}
      #                      ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.Alpha
        alias Qez.Bar
        alias Qez.Delta
      end
      """
    )
  end

  test "expands the selected nested alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        #          v
        alias Qez.{Bar, Delta}
        #            ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.{Delta}
        alias Qez.Bar
      end
      """
    )
  end

  test "expands the selected single nested alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        #          v
        alias Qez.{Bar}
        #            ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.Bar
      end
      """
    )
  end

  test "expands the selected single deeply nested  alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        alias Qez.{
          Alpha,
        #        v
          Delta.{Bar}
        #          ^
        }
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Alpha
        }

        alias Qez.Delta.Bar
      end
      """
    )
  end

  test "expands the selected multiple nested alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        alias Qez.{
          Alpha,
        # v
          Delta.{Bar, Test.{A, B}, Foo}
        #                             ^
        }
      end
      """,
      """
      defmodule Foo do
        alias Qez.{
          Alpha
        }

        alias Qez.Delta.Bar
        alias Qez.Delta.Test.A
        alias Qez.Delta.Test.B
        alias Qez.Delta.Foo
      end
      """
    )
  end

  test "expands the whole selected alias" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
      # v
        alias Qez.{
          Alpha,
          Delta.{Bar, Test}
        }
      # ^
      end
      """,
      """
      defmodule Foo do
        alias Qez.Alpha
        alias Qez.Delta.Bar
        alias Qez.Delta.Test
      end
      """
    )
  end

  test "expand two merged alias selecting on the tuple" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
        #         v
        alias Foo.{Bar, Qez}
        #                  ^
      end
      """,
      """
      defmodule Foo do
        alias Foo.Bar
        alias Foo.Qez
      end
      """
    )
  end

  test "expands __MODULE__ aliases" do
    assert_refactored(
      ExpandAliases,
      """
      defmodule Foo do
      # v
        alias __MODULE__.{
          Alpha,
          Delta.{Bar, Test}
        }
      # ^
      end
      """,
      """
      defmodule Foo do
        alias __MODULE__.Alpha
        alias __MODULE__.Delta.Bar
        alias __MODULE__.Delta.Test
      end
      """
    )
  end

  test "ignores outside module" do
    assert_ignored(
      ExpandAliases,
      """
      #          v
      alias Foo.{Bar}
      #            ^
      """
    )
  end

  test "ignores outside alias" do
    assert_ignored(
      ExpandAliases,
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
end
