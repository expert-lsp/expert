# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Guard.ExtractGuardTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Guard.ExtractGuard

  test "extracts statement from WHEN to guard" do
    assert_refactored(
      ExtractGuard,
      """
      defmodule Foo do
        #                 v
        def foo(arg) when arg.valid? == true do
        #                                  ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        def foo(arg) when extracted_guard(arg) do
          arg
        end
      end
      """
    )
  end

  test "extracts part of statement connected by AND or OR" do
    assert_refactored(
      ExtractGuard,
      """
      defmodule Foo do
        def foo(arg) do
          case arg do
            #        v
            arg when arg.valid? == true and is_map(arg) ->
            #                         ^
              true

            _ ->
              false
          end
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        def foo(arg) do
          case arg do
            arg when extracted_guard(arg) and is_map(arg) ->
              true

            _ ->
              false
          end
        end
      end
      """
    )
  end

  test "extracts part of statement after NOT" do
    assert_refactored(
      ExtractGuard,
      """
      defmodule Foo do
        #                     v
        def foo(arg) when not (arg.valid? == true) do
        #                                        ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard(arg) when arg.valid? == true

        def foo(arg) when not extracted_guard(arg) do
          arg
        end
      end
      """
    )
  end

  test "extracts guard using an unique name" do
    assert_refactored(
      ExtractGuard,
      """
      defmodule Foo do
        defguard extracted_guard(arg) when arg == true

        defguardp extracted_guard1(arg) when arg == true

        #                 v
        def foo(arg) when arg == true do
        #                           ^
          arg
        end
      end
      """,
      """
      defmodule Foo do
        defguardp extracted_guard2(arg) when arg == true
        defguard extracted_guard(arg) when arg == true

        defguardp extracted_guard1(arg) when arg == true

        def foo(arg) when extracted_guard2(arg) do
          arg
        end
      end
      """
    )
  end

  test "ignores statements outside modules" do
    assert_ignored(
      ExtractGuard,
      """
      #                 v
      def foo(arg) when arg.valid? == true do
      #                                  ^
        arg
      end
      """
    )
  end

  test "ignores statements outside WHEN" do
    assert_ignored(
      ExtractGuard,
      """
      defmodule Foo do
        #       v
        def foo(arg) when arg.valid? == true do
        #         ^
          arg
        end
      end
      """
    )
  end

  test "ignores incomplete statements" do
    assert_ignored(
      ExtractGuard,
      """
      defmodule Foo do
        #                 v
        def foo(arg) when arg.valid? == true do
        #                          ^
          arg
        end
      end
      """
    )
  end
end
