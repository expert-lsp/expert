# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.ExtractAnonymousFunctionTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Function.ExtractAnonymousFunction

  test "extracts anonymous function to a private function" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def read_files do
          filenames
          #           v
          |> Enum.map(fn filename -> File.read!(filename) end)
          #                                                 ^
          |> Enum.join("")
        end
      end
      """,
      """
      defmodule Foo do
        def read_files do
          filenames
          |> Enum.map(&extracted_function(&1))
          |> Enum.join("")
        end

        defp extracted_function(filename) do
          File.read!(filename)
        end
      end
      """
    )
  end

  test "extracts anonymous function always put it on the end of module" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def read_files do
          filenames
          #           v
          |> Enum.map(fn filename -> File.read!(filename) end)
          #                                                 ^
          |> Enum.join("")
        end

        def foo(arg), do: arg
      end
      """,
      """
      defmodule Foo do
        def read_files do
          filenames
          |> Enum.map(&extracted_function(&1))
          |> Enum.join("")
        end

        def foo(arg), do: arg

        defp extracted_function(filename) do
          File.read!(filename)
        end
      end
      """
    )
  end

  test "extracts anonymous function with N arguments" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def sum(numbers) do
          #                       v
          Enum.reduce(numbers, 0, fn i, acc -> i + acc end)
          #                                              ^
        end
      end
      """,
      """
      defmodule Foo do
        def sum(numbers) do
          Enum.reduce(numbers, 0, &extracted_function(&1, &2))
        end

        defp extracted_function(i, acc) do
          i + acc
        end
      end
      """
    )
  end

  test "extracts anonymous function with capture syntax" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def filter_methods(methods) do
          Enum.filter(
            methods,
          # v
            &(&1["type"] in ~w(clicktopay scheme))
          #                                      ^
          )
        end
      end
      """,
      """
      defmodule Foo do
        def filter_methods(methods) do
          Enum.filter(
            methods,
            &extracted_function(&1)
          )
        end

        defp extracted_function(arg1) do
          arg1["type"] in ~w(clicktopay scheme)
        end
      end
      """
    )
  end

  test "extracts anonymous function with capture syntax and N arguments" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def power_sum(numbers, power) do
          #                       v
          Enum.reduce(numbers, 0, &(pow(&1, power) - &1 + &2))
          #                                                 ^
        end
      end
      """,
      """
      defmodule Foo do
        def power_sum(numbers, power) do
          Enum.reduce(numbers, 0, &extracted_function(&1, &2, power))
        end

        defp extracted_function(arg1, arg2, power) do
          pow(arg1, power) - arg1 + arg2
        end
      end
      """
    )
  end

  test "extracts anonymous function with multiple clauses" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Payment do
        def pay(payload) do
          error_code = "ERROR_999"

          payload
          |> post()
          #       v
          |> then(fn
            {:ok, %{status: status}} when status in ~w(paid) ->
              {:reply, "PAID"}

            {:ok, _response} ->
              {:reply, error_code}

            {:error, _error} ->
              {:reply, error_code}
          end)
          # ^
        end
      end
      """,
      """
      defmodule Payment do
        def pay(payload) do
          error_code = "ERROR_999"

          payload
          |> post()
          |> then(
            &extracted_function(
              &1,
              error_code
            )
          )
        end

        defp extracted_function({:ok, %{status: status}}, error_code) when status in ~w(paid) do
          {:reply, "PAID"}
        end

        defp extracted_function({:ok, _response}, error_code) do
          {:reply, error_code}
        end

        defp extracted_function({:error, _error}, error_code) do
          {:reply, error_code}
        end
      end
      """
    )
  end

  test "extracts anonymous function with multiple statements" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def read_files(filenames, ext) do
          filenames
          #           v
          |> Enum.map(fn filename ->
            file = File.read!("\#{filename}.\#{ext}")
            String.split(file, "\\n")
          end)
          # ^
        end
      end
      """,
      """
      defmodule Foo do
        def read_files(filenames, ext) do
          filenames
          |> Enum.map(
            &extracted_function(
              &1,
              ext
            )
          )
        end

        defp extracted_function(filename, ext) do
          file = File.read!("\#{filename}.\#{ext}")
          String.split(file, "\\n")
        end
      end
      """
    )
  end

  test "extracts anonymous function with pin operator" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def confirm_key(payload, key) do
          payload
          #       v
          |> post(fn
            {:ok, %{key: ^key} = response} ->
              {:ok, response}

            _ ->
              {:error, :invalid_key}
          end)
          # ^
        end
      end
      """,
      """
      defmodule Foo do
        def confirm_key(payload, key) do
          payload
          |> post(
            &extracted_function(
              &1,
              key
            )
          )
        end

        defp extracted_function({:ok, %{key: key} = response}, key) do
          {:ok, response}
        end

        defp extracted_function(_, key) do
          {:error, :invalid_key}
        end
      end
      """
    )
  end

  test "extracts anonymous function that is outside a module function" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        @response "PAID"

        #                           v
        mock({PaymentService, [pay: fn _, _ -> {:ok, @response} end]})
        #                                                         ^
      end
      """,
      """
      defmodule Foo do
        @response "PAID"

        mock({PaymentService, [pay: &extracted_function(&1, &2)]})

        defp extracted_function(_, _) do
          {:ok, @response}
        end
      end
      """
    )
  end

  test "extracts anonymous function that uses outer scope variables" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def files(folders) do
          file = "foo"
          ext = "ex"

          folders
          #           v
          |> Enum.map(fn folder -> "\#{folder}/\#{file}_\#{file}.\#{ext}" end)
          #                         \          \        \        \          ^
        end
      end
      """,
      """
      defmodule Foo do
        def files(folders) do
          file = "foo"
          ext = "ex"

          folders
          |> Enum.map(&extracted_function(&1, file, ext))
        end

        defp extracted_function(folder, file, ext) do
          "\#{folder}/\#{file}_\#{file}.\#{ext}"
        end
      end
      """
    )
  end

  test "extracts anonymous function that receives a tuple" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Circles do
        @pi 3.14

        def areas(circles) do
          circles
          |> Enum.with_index()
          #           v
          |> Enum.map(fn {%{radius: r}, i} -> {pow(r, 2) * @pi, i} end)
          #                                                          ^
        end
      end
      """,
      """
      defmodule Circles do
        @pi 3.14

        def areas(circles) do
          circles
          |> Enum.with_index()
          |> Enum.map(&extracted_function(&1))
        end

        defp extracted_function({%{radius: r}, i}) do
          {pow(r, 2) * @pi, i}
        end
      end
      """
    )
  end

  test "extracts anonymous function with a new unique name" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Circles do
        @pi 3.14

        def areas(circles) do
          circles
          |> Enum.with_index()
          #           v
          |> Enum.map(fn %{radius: r} -> r end)
          #                                  ^
        end

        def extracted_function(_), do: 0

        defp extracted_function1(_), do: 2
      end
      """,
      """
      defmodule Circles do
        @pi 3.14

        def areas(circles) do
          circles
          |> Enum.with_index()
          |> Enum.map(&extracted_function2(&1))
        end

        def extracted_function(_), do: 0

        defp extracted_function1(_), do: 2

        defp extracted_function2(%{radius: r}) do
          r
        end
      end
      """
    )
  end

  test "extracts anonymous function from other modules" do
    assert_refactored(
      ExtractAnonymousFunction,
      """
      defmodule Chef do
        def grab_ingredients(recipe, pantry) do
          #                   v
          Enum.filter(pantry, &Enum.member?(recipe.ingredients, &1))
          #                                                       ^
        end
      end
      """,
      """
      defmodule Chef do
        def grab_ingredients(recipe, pantry) do
          Enum.filter(pantry, &extracted_function(&1, recipe))
        end

        defp extracted_function(arg1, recipe) do
          Enum.member?(recipe.ingredients, arg1)
        end
      end
      """
    )
  end

  test "ignores anonymous function that is not inside a module" do
    assert_ignored(
      ExtractAnonymousFunction,
      """
      def power_sum(numbers, power) do
        #                       v
        Enum.reduce(numbers, 0, &(pow(&1, power) + &2))
        #                                            ^
      end
      """
    )
  end

  test "ignores anonymous function with zero arguments" do
    assert_ignored(
      ExtractAnonymousFunction,
      """
      defmodule Middleware do
        def call(env, next) do
          #        v
          duration(fn -> Tesla.run(env, next) end)
          #                                     ^
        end
      end
      """
    )
  end

  test "ignores already extracted function" do
    assert_ignored(
      ExtractAnonymousFunction,
      """
      defmodule Foo do
        def foo(arg) do
          arg
          #           v
          |> Enum.map(&extracted_function1(&1))
          #                                  ^
        end
      end
      """
    )
  end
end
