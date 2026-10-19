# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Constant.ExtractConstantTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Constant.ExtractConstant

  test "extracts selection range into a module constant" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
      #                v
        @foo %{status: "PAID"}
      #                     ^
      end
      """,
      """
      defmodule Foo do
        @extracted_constant "PAID"

        @foo %{status: @extracted_constant}
      end
      """
    )
  end

  test "extracts zero arg function into constant" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
        def foo(arg) do
        # v
          bar()
        #     ^
        end
      end
      """,
      """
      defmodule Foo do
        @extracted_constant bar()

        def foo(arg) do
          @extracted_constant
        end
      end
      """
    )
  end

  test "extracts node that uses other constants" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
        @skipped_constant :skipped
        @first_constant 10
        #                         v
        @second_constant %{range: %{start: @first_constant, end: 14}}
        #                                                          ^
      end
      """,
      """
      defmodule Foo do
        @skipped_constant :skipped
        @first_constant 10
        @extracted_constant %{start: @first_constant, end: 14}

        @second_constant %{range: @extracted_constant}
      end
      """
    )
  end

  test "extracts constant with new unique name" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
        @extracted_constant "REFUNDED"
        @extracted_constant1 "AUTHORIZED"
      #                v
        @foo %{status: "PAID"}
      #                     ^
      end
      """,
      """
      defmodule Foo do
        @extracted_constant2 "PAID"

        @extracted_constant "REFUNDED"
        @extracted_constant1 "AUTHORIZED"
        @foo %{status: @extracted_constant2}
      end
      """
    )
  end

  test "extracts multiline selection into constant" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
        def foo do
        # v
          :foo
          |> bar()
          |> baz()
        #        ^
        end
      end
      """,
      """
      defmodule Foo do
        @extracted_constant :foo
                            |> bar()
                            |> baz()

        def foo do
          @extracted_constant
        end
      end
      """
    )
  end

  test "extracts constant after some reserved keywords" do
    assert_refactored(
      ExtractConstant,
      """
      defmodule Foo do
        use Bar
        alias Bar
        import Bar
        require Logger

        @behaviour Baz

        def foo(arg) do
        # v
          bar()
        #     ^
        end
      end
      """,
      """
      defmodule Foo do
        use Bar
        alias Bar
        import Bar
        require Logger

        @behaviour Baz

        @extracted_constant bar()

        def foo(arg) do
          @extracted_constant
        end
      end
      """
    )
  end

  test "ignores constants" do
    assert_ignored(
      ExtractConstant,
      """
      defmodule Foo do
        @other_constant 10

        def foo(arg) do
        # v
          @other_constant
        #               ^
          |> bar()
        end
      end
      """
    )
  end

  test "ignores anonymous function" do
    assert_ignored(
      ExtractConstant,
      """
      defmodule Foo do
        @other_constant 10

        def foo(arg) do
        #               v
          Enum.map(arg, &(&1 + 2))
        #                       ^
        end
      end
      """
    )
  end

  test "ignores selection ranges with variables" do
    assert_ignored(
      ExtractConstant,
      """
      defmodule Foo do
        def foo(arg) do
        # v
          bar(arg)
        #        ^
        end
      end
      """
    )
  end

  test "ignores pipe function calls" do
    assert_ignored(
      ExtractConstant,
      """
      defmodule Foo do
        def foo(arg) do
        #         v
          args |> bar()
        #             ^
        end
      end
      """
    )
  end

  test "ignores selection ranges outside modules" do
    assert_ignored(
      ExtractConstant,
      """
      #               v
      foo = %{status: "PAID"}
      #                    ^
      """
    )
  end

  test "ignores alias" do
    assert_ignored(
      ExtractConstant,
      """
      defmodule Foo do
      # v
        alias Foo.Bar
      #             ^
      end
      """
    )
  end
end
