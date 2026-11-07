# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.IntroducePipeTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Pipeline.IntroducePipe

  test "pipes the first argument into the function" do
    assert_refactored(
      IntroducePipe,
      """
      def some_function(arg1, arg2) do
        #   v
        foo(arg1, arg2)
      end
      """,
      """
      def some_function(arg1, arg2) do
        arg1 |> foo(arg2)
      end
      """
    )
  end

  test "pipes outside function blocks" do
    assert_refactored(
      IntroducePipe,
      """
      defmodule Foo do
        #      v
        @bar bar(arg)
      end
      """,
      """
      defmodule Foo do
        @bar arg |> bar()
      end
      """
    )
  end

  test "pipes without changing the surroundings" do
    assert_refactored(
      IntroducePipe,
      """
      def some_function(arg1) do
        arg2 = :bar

        # v
        foo(arg1, arg2)
        |> other_function()
      end
      """,
      """
      def some_function(arg1) do
        arg2 = :bar

        arg1
        |> foo(arg2)
        |> other_function()
      end
      """
    )
  end

  test "pipes function inside other structures" do
    assert_refactored(
      IntroducePipe,
      """
      defmodule Foo do
        #            v
        @bar %{ok: bar(arg)}
      end
      """,
      """
      defmodule Foo do
        @bar %{ok: arg |> bar()}
      end
      """
    )
  end

  test "pipes the fist argument into module function" do
    assert_refactored(
      IntroducePipe,
      """
      def foo do
        #      v
        Elixir.File.write!("foo.ex")
      end
      """,
      """
      def foo do
        "foo.ex" |> Elixir.File.write!()
      end
      """
    )
  end

  test "pipes the first argument into variable module" do
    assert_refactored(
      IntroducePipe,
      """
      def foo(module) do
        #             v
        module.use("foo.ex")
      end
      """,
      """
      def foo(module) do
        "foo.ex" |> module.use()
      end
      """
    )
  end

  test "pipes function from other argument two levels deep" do
    assert_refactored(
      IntroducePipe,
      """
      def foo(map) do
        #             v
        map.adapter.use("foo.ex")
      end
      """,
      """
      def foo(map) do
        "foo.ex" |> map.adapter.use()
      end
      """
    )
  end

  test "pipes function inside anonymous function" do
    assert_refactored(
      IntroducePipe,
      """
      list
      #                     v
      |> Enum.map(fn i -> foo(i) end)
      """,
      """
      list
      |> Enum.map(fn i -> i |> foo() end)
      """
    )
  end

  test "pipes argument into case block" do
    assert_refactored(
      IntroducePipe,
      """
      #   v
      case list do
        [] -> :empty
        _ -> :not_empty
      end
      """,
      """
      list
      |> case do
        [] -> :empty
        _ -> :not_empty
      end
      """
    )
  end

  test "pipes argument into multiline function" do
    assert_refactored(
      IntroducePipe,
      """
      #  v
      post(
        payment
        |> client(),
        "/payments",
        Sale.format(payment)
      )
      """,
      """
      payment
      |> client()
      |> post(
        "/payments",
        Sale.format(payment)
      )
      """
    )
  end

  test "ignores already piped functions" do
    assert_ignored(
      IntroducePipe,
      """
      #        v
      arg1 |> foo(arg2)
      """
    )
  end

  test "ignores access operations" do
    assert_ignored(
      IntroducePipe,
      """
      #    v
      foo[:bar]
      """
    )
  end

  test "ignores functions without at least one argument" do
    assert_ignored(
      IntroducePipe,
      """
      def bar do
        #  v
        foo()
      end
      """
    )
  end

  # test "ignores functions outside range" do
  #   assert_ignored(
  #     IntroducePipe,
  #     """
  #     def some_function do
  #       #  v
  #       foo = bar(10) + 12
  #     end
  #     """
  #   )

  #   assert_ignored(
  #     IntroducePipe,
  #     """
  #     def some_function do
  #       #              v
  #       foo = bar(10) + 12
  #     end
  #     """
  #   )
  # end

  test "ignores anonymous functions" do
    assert_ignored(
      IntroducePipe,
      """
      list
      #        v
      |> Enum.map(fn i -> i * 2 end)
      """
    )
  end

  test "ignores alias" do
    assert_ignored(
      IntroducePipe,
      """
      #        v
      alias Foo.{Bar, Delta}
      """
    )
  end

  test "ignores function declarations" do
    assert_ignored(
      IntroducePipe,
      """
      #    v
      def foo(arg) do
        bar(arg)
      end
      """
    )
  end

  test "ignores function declaration with when clause" do
    assert_ignored(
      IntroducePipe,
      """
      #    v
      def into_map(%name{} = struct)
        when name in [Date, DateTime],
        do: struct
      """
    )
  end

  test "ignores every thing that is not a function call" do
    assert_ignored(
      IntroducePipe,
      """
      #    v
      foo = %{list: [1, 2, 3]}
      """
    )

    assert_ignored(
      IntroducePipe,
      """
      #    v
      [1, 2, 3]
      """
    )

    assert_ignored(
      IntroducePipe,
      """
      #    v
      {1, 2, 3}
      """
    )

    assert_ignored(
      IntroducePipe,
      """
      #    v
      fn {key, _} -> "\#{key}" end
      """
    )
  end

  test "ignores range if it's not empty" do
    assert_ignored(
      IntroducePipe,
      """
      def some_function(arg1, arg2) do
        #   v
        foo(arg1, arg2)
        #     ^
      end
      """
    )
  end
end
