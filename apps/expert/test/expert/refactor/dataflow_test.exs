# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.DataflowTest do
  use ExUnit.Case

  alias Expert.Refactor.AST
  alias Expert.Refactor.Dataflow

  test "lists all variables inside simple function with constants" do
    assert_has_variables(
      """
      def bar(arg1, arg2 \\\\ @arg2) do
        arg2 + arg1 + @arg1
      end
      """,
      %{
        variable(:arg1, 1, 9) => [variable(:arg1, 2, 10)],
        variable(:arg2, 1, 15) => [variable(:arg2, 2, 3)]
      }
    )
  end

  test "lists all variables inside same arg twice function" do
    assert_has_variables(
      """
      defp bar(%{arg: arg}, arg), do: arg
      """,
      %{
        variable(:arg, 1, 17) => [
          variable(:arg, 1, 33),
          variable(:arg, 1, 23)
        ]
      }
    )
  end

  test "lists all variables inside function with guard" do
    assert_has_variables(
      """
      defp bar(arg) when arg > 10 do
      end
      """,
      %{variable(:arg, 1, 10) => [variable(:arg, 1, 20)]}
    )
  end

  test "lists all variables inside anonymous function" do
    assert_has_variables(
      """
      defp bar(list, arg1) do
        Enum.map(list, fn
          ^arg1 ->
             arg1

          %{arg1: arg1} when arg1 > 10 ->
            arg1
        end)

        arg1
      end
      """,
      %{
        variable(:list, 1, 10) => [
          variable(:list, 2, 12)
        ],
        variable(:arg1, 1, 16) => [
          variable(:arg1, 10, 3),
          variable(:arg1, 4, 8),
          variable(:arg1, 3, 6)
        ],
        variable(:arg1, 6, 13) => [
          variable(:arg1, 7, 7),
          variable(:arg1, 6, 24)
        ]
      }
    )
  end

  test "lists all variables inside guard" do
    assert_has_variables(
      """
      defguard guard(arg) when arg < 10
      """,
      %{variable(:arg, 1, 16) => [variable(:arg, 1, 26)]}
    )
  end

  test "lists all variables reused by guards" do
    assert_has_variables(
      """
      defp bar() do
        arg = 10

        1..30
        |> Enum.map(fn
          i when i <= arg -> i
          i when i > arg -> i + 10
        end)

       with true when arg > 10 <- true do
       end
      end
      """,
      %{
        variable(:arg, 2, 3) => [
          variable(:arg, 10, 17),
          variable(:arg, 7, 16),
          variable(:arg, 6, 17)
        ]
      }
    )
  end

  test "lists all variables after a reassignment" do
    assert_has_variables(
      """
      def bar(arg) do
        arg = arg + 10
        arg * 20
      end
      """,
      %{
        variable(:arg, 1, 9) => [variable(:arg, 2, 9)],
        variable(:arg, 2, 3) => [variable(:arg, 3, 3)]
      }
    )
  end

  test "lists all variables inside CASE statement" do
    assert_has_variables(
      """
      def bar(arg1, arg2) do
        case arg2 = arg1 + arg2 do
          20 ->
            arg2 = arg2 + 5
            arg2 + 40

          arg1 when arg1 < 1 ->
            arg1 + 12
        end

        arg2 + arg1
      end
      """,
      %{
        variable(:arg1, 1, 9) => [
          variable(:arg1, 11, 10),
          variable(:arg1, 2, 15)
        ],
        variable(:arg2, 1, 15) => [
          variable(:arg2, 11, 3),
          variable(:arg2, 2, 22)
        ],
        variable(:arg2, 2, 8) => [
          variable(:arg2, 4, 14)
        ],
        variable(:arg2, 4, 7) => [
          variable(:arg2, 5, 7)
        ],
        variable(:arg1, 7, 5) => [
          variable(:arg1, 8, 7),
          variable(:arg1, 7, 15)
        ]
      }
    )
  end

  test "lists all variables inside COND statement" do
    assert_has_variables(
      """
      def bar(arg) do
        cond do
          arg == 15 ->
            arg * 15

          arg = arg + 10 when arg > 10 ->
            arg * 10
        end

        arg
      end
      """,
      %{
        variable(:arg, 1, 9) => [
          variable(:arg, 10, 3),
          variable(:arg, 6, 11),
          variable(:arg, 4, 7),
          variable(:arg, 3, 5)
        ],
        variable(:arg, 6, 5) => [
          variable(:arg, 7, 7),
          variable(:arg, 6, 25)
        ]
      }
    )
  end

  test "lists all variables inside WITH statement" do
    assert_has_variables(
      """
      def bar(arg1) do
        with arg2 <- arg1,
             %{arg: ^arg1} <- arg2,
             arg1 = arg1 <- arg2,
             arg2 when arg2 < 20 <- arg1 do
          arg1 = arg2 + arg1
          arg1 * 10
        else
          e -> arg1 + e
          arg1 -> arg1
        end

        arg1
      end
      """,
      %{
        variable(:arg1, 1, 9) => [
          variable(:arg1, 13, 3),
          variable(:arg1, 9, 10),
          variable(:arg1, 3, 16),
          variable(:arg1, 2, 16)
        ],
        variable(:arg2, 2, 8) => [
          variable(:arg2, 4, 23),
          variable(:arg2, 3, 25)
        ],
        variable(:arg1, 4, 8) => [
          variable(:arg1, 6, 19),
          variable(:arg1, 5, 31),
          variable(:arg1, 4, 15)
        ],
        variable(:arg2, 5, 8) => [
          variable(:arg2, 6, 12),
          variable(:arg2, 5, 18)
        ],
        variable(:arg1, 6, 5) => [
          variable(:arg1, 7, 5)
        ],
        variable(:e, 9, 5) => [
          variable(:e, 9, 17)
        ],
        variable(:arg1, 10, 5) => [
          variable(:arg1, 10, 13)
        ]
      }
    )
  end

  test "lists all variables inside TRY statement" do
    assert_has_variables(
      """
      def bar(arg) do
        try do
          arg = arg * 15
          arg + 10
        rescue
          arg -> arg
        catch
          e -> e + arg
        after
          arg = arg + 10
          arg
        end

        arg
      end
      """,
      %{
        variable(:arg, 1, 9) => [
          variable(:arg, 14, 3),
          variable(:arg, 10, 11),
          variable(:arg, 8, 14),
          variable(:arg, 3, 11)
        ],
        variable(:arg, 3, 5) => [
          variable(:arg, 4, 5)
        ],
        variable(:arg, 6, 5) => [
          variable(:arg, 6, 12)
        ],
        variable(:e, 8, 5) => [
          variable(:e, 8, 10)
        ],
        variable(:arg, 10, 5) => [
          variable(:arg, 11, 5)
        ]
      }
    )
  end

  test "lists all variables inside IF statement" do
    assert_has_variables(
      """
      def bar(arg) do
        if arg = arg + 10 do
          arg = arg * 15
          arg + 10
        else
          arg = arg * 20
          arg + 25
        end

        arg
      end
      """,
      %{
        variable(:arg, 1, 9) => [
          variable(:arg, 10, 3),
          variable(:arg, 2, 12)
        ],
        variable(:arg, 2, 6) => [
          variable(:arg, 6, 11),
          variable(:arg, 3, 11)
        ],
        variable(:arg, 3, 5) => [
          variable(:arg, 4, 5)
        ],
        variable(:arg, 6, 5) => [
          variable(:arg, 7, 5)
        ]
      }
    )
  end

  test "lists all variables inside UNLESS statement" do
    assert_has_variables(
      """
      def bar(arg) do
        unless arg = arg + 10 do
          arg = arg * 15
          arg + 10
        else
          arg = arg * 20
          arg + 25
        end

        arg
      end
      """,
      %{
        variable(:arg, 1, 9) => [
          variable(:arg, 10, 3),
          variable(:arg, 2, 16)
        ],
        variable(:arg, 2, 10) => [
          variable(:arg, 6, 11),
          variable(:arg, 3, 11)
        ],
        variable(:arg, 3, 5) => [
          variable(:arg, 4, 5)
        ],
        variable(:arg, 6, 5) => [
          variable(:arg, 7, 5)
        ]
      }
    )
  end

  test "lists all variables inside FOR statement" do
    assert_has_variables(
      """
      def bar(arg1) do
        for arg2 <- 1..5,
            arg2 = arg2 + 10,
            arg1 <- 0..arg1,
            arg1 + arg2 < 4,
            into: %{} do
          arg1 = {arg1, arg2}
          arg1
        end

        arg1
      end
      """,
      %{
        variable(:arg1, 1, 9) => [
          variable(:arg1, 11, 3),
          variable(:arg1, 4, 18)
        ],
        variable(:arg2, 2, 7) => [
          variable(:arg2, 3, 14)
        ],
        variable(:arg2, 3, 7) => [
          variable(:arg2, 7, 19),
          variable(:arg2, 5, 14)
        ],
        variable(:arg1, 4, 7) => [
          variable(:arg1, 7, 13),
          variable(:arg1, 5, 7)
        ],
        variable(:arg1, 7, 5) => [
          variable(:arg1, 8, 5)
        ]
      }
    )
  end

  test "lists all variables inside test macro" do
    assert_has_variables(
      """
      defmodule Test do
        arg = 10

        test "test with variables", %{arg: arg} do
          arg = arg + 10
          arg
        end

        test "test with variables" do
          arg # ignored
          arg = arg + 20
          arg
        end

        arg
      end
      """,
      %{
        variable(:arg, 2, 3) => [
          variable(:arg, 15, 3)
        ],
        variable(:arg, 4, 38) => [
          variable(:arg, 5, 11)
        ],
        variable(:arg, 5, 5) => [
          variable(:arg, 6, 5)
        ],
        variable(:arg, 11, 5) => [
          variable(:arg, 12, 5)
        ]
      }
    )
  end

  test "lists all variables inside module" do
    assert_has_variables(
      """
      defmodule Outer do
        arg = 10

        defmodule Mod do
          arg = arg + 20

          def function() do
            arg # ignored
          end

          def function2(arg) do
            arg
          end

          arg
        end

        arg + 20
      end
      """,
      %{
        variable(:arg, 2, 3) => [
          variable(:arg, 18, 3),
          variable(:arg, 5, 11)
        ],
        variable(:arg, 5, 5) => [
          variable(:arg, 15, 5)
        ],
        variable(:arg, 11, 19) => [
          variable(:arg, 12, 7)
        ]
      }
    )
  end

  test "outer_variables returns only variables used but not declared in a block with an assignment" do
    node =
      Sourceror.parse_string!("""
      foo = 42
      my_fun(x)
      """)

    result =
      node
      |> Dataflow.outer_variables()
      |> Enum.map(&AST.simpler_meta/1)

    assert result == [variable(:x, 2, 8)]
  end

  test "outer_variables returns empty list when selection declares a variable and uses no outer ones" do
    node = Sourceror.parse_string!("foo = 42")

    assert Dataflow.outer_variables(node) == []
  end

  test "outer_variables returns outer variable used in an assignment right-hand side" do
    node = Sourceror.parse_string!("foo = x + 1")

    result =
      node
      |> Dataflow.outer_variables()
      |> Enum.map(&AST.simpler_meta/1)

    assert result == [variable(:x, 1, 7)]
  end

  describe "outer_variables/1" do
    test "returns variables used but not declared in the node" do
      ast = Sourceror.parse_string!("use_it(env)")

      assert [{:env, _, nil}] = Dataflow.outer_variables(ast)
    end

    test "returns no outer variables when every used variable is locally declared" do
      ast =
        Sourceror.parse_string!("""
        env = build_env()
        use_it(env)
        """)

      assert Dataflow.outer_variables(ast) == []
    end

    test "ignores local declarations even when never used and node is not scope-wrapped" do
      ast = Sourceror.parse_string!("env = build_env()")

      assert Dataflow.outer_variables(ast) == []
    end

    test "returns only the variables that come from outside the node" do
      ast =
        Sourceror.parse_string!("""
        local = compute(outer1)
        use_it(local, outer2)
        """)

      assert [{:outer1, _, nil}, {:outer2, _, nil}] = Dataflow.outer_variables(ast)
    end
  end

  defp assert_has_variables(original, expected_variables) do
    found_variables =
      original
      |> Sourceror.parse_string!()
      |> Dataflow.group_variables_semantically()
      |> Map.new(&AST.simpler_meta/1)

    for {definition, usages} <- expected_variables do
      assert is_map_key(found_variables, definition)
      assert usages == found_variables[definition]
    end
  end

  defp variable(name, line, column),
    do: {name, [line: line, column: column], nil}
end
