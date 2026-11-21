# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Guard.InlineGuardTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Guard.InlineGuard

  test "inlines the selected guard call but never remove the definition" do
    assert_refactored(
      InlineGuard,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        #                 v
        def foo(arg) when extracted_guard(arg) do
        #                                    ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        def foo(arg) when arg.valid? == true do
          arg
        end
      end
      """
    )
  end

  test "inlines the guard with same arity" do
    assert_refactored(
      InlineGuard,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when true
        defguardp extracted_guard(arg1, arg2) when false

        #                 v
        def foo(arg) when extracted_guard(arg, arg) or true do
        #                                         ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when true
        defguardp extracted_guard(arg1, arg2) when false

        def foo(arg) when false or true do
          arg
        end
      end
      """
    )
  end

  test "inlines guard call with correctly reassigned args" do
    assert_refactored(
      InlineGuard,
      """
      defmodule Foo do
        @arg1 42

        defguard extracted_guard(arg1, arg2) when arg1.v2 + arg2 < arg2 * (arg1.v1 - @arg1)

        #                  v
        def foo(a, b) when extracted_guard(b.value, a - @arg1) do
        #                                                    ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        @arg1 42

        defguard extracted_guard(arg1, arg2) when arg1.v2 + arg2 < arg2 * (arg1.v1 - @arg1)

        def foo(a, b) when b.value.v2 + (a - @arg1) < (a - @arg1) * (b.value.v1 - @arg1) do
          arg
        end
      end
      """
    )
  end

  test "ignores guard definition" do
    assert_ignored(
      InlineGuard,
      """
      defmodule Foo do
        #        v
        defguard extracted_guard(arg) when arg.valid? == true
        #                           ^

        def foo(arg) when extracted_guard(arg) do
          arg
        end
      end
      """
    )
  end

  test "ignores guard call outside module" do
    assert_ignored(
      InlineGuard,
      """
      #                 v
      def foo(arg) when extracted_guard(arg) do
      #                                    ^
        arg
      end
      """
    )
  end

  test "ignores guard call when the definition is not found" do
    assert_ignored(
      InlineGuard,
      """
       defmodule Foo do
        import Foo.Guards

        #                 v
        def foo(arg) when extracted_guard(arg) do
        #                                    ^
          arg
        end
      end
      """
    )
  end

  test "ignores other guards statements" do
    assert_ignored(
      InlineGuard,
      """
       defmodule Foo do
        import Foo.Guards

        #                 v
        def foo(arg) when 1 == 2  do
        #                      ^
          arg
        end
      end
      """
    )
  end

  test "ignores function call with the same name" do
    assert_ignored(
      InlineGuard,
      """
       defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        def foo(arg) do
        # v
          extracted_guard(arg)
        #                    ^
        end
      end
      """
    )
  end
end
