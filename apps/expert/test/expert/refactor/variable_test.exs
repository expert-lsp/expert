# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.VariableTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.Variable
  alias Sourceror.Zipper

  describe "inside_declaration?/1" do
    test "marks function arg as declaration" do
      zipper =
        go_to_selection("""
        #                  v
        def foo(%{"arg" => arg}) when arg == 10 do
        #                    ^
          arg + 10
        end
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "marks nested function arg as declaration" do
      zipper =
        go_to_selection("""
        #                              v
        def foo(%{"arg" => [_, {%{arg: arg}, _}]}) when arg == 10 do
        #                                ^
          arg + 10
        end
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "marks CASE clause arg as declaration" do
      zipper =
        go_to_selection("""
        case arg do
          %{foo: 32} -> 32
          #      v
          %{foo: foo} -> foo + 4
          #        ^
          _ -> 42
        end
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "marks WITH clause arg as declaration" do
      zipper =
        go_to_selection("""
        #          v
        with {:ok, arg} <- foo(b) do
        #            ^
          arg2
        end
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "marks anonymous function arg as declaration" do
      zipper =
        go_to_selection("""
        #  v
        fn arg -> arg + 40 end
        #    ^
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "marks everything inside guard as declaration" do
      zipper =
        go_to_selection("""
        #                 v
        def foo(arg) when arg == 10 do
        #                   ^
          arg + 45
        end
        """)

      assert Variable.inside_declaration?(zipper)

      zipper =
        go_to_selection("""
        #            v
        defguard foo(arg) when arg == 10
        #              ^
        """)

      assert Variable.inside_declaration?(zipper)
    end

    test "doesn't mark variable usage as declaration" do
      zipper =
        go_to_selection("""
        def foo(arg) do
        # v
          foo + 10
        #   ^
        end
        """)

      refute Variable.inside_declaration?(zipper)
    end

    test "doesn't mark function call as declaration" do
      zipper =
        go_to_selection("""
        def foo(arg) do
        # v
          bar(foo) + 10
        #        ^
        end
        """)

      refute Variable.inside_declaration?(zipper)
    end

    test "doesn't mark COND clause as declaration" do
      zipper =
        go_to_selection("""
        def foo(arg) do
          cond do
          # v
            arg == 10 ->
          #   ^
              arg

            true ->
              arg + 10
          end
        end
        """)

      refute Variable.inside_declaration?(zipper)
    end

    defp go_to_selection(original) do
      range = range_from_markers(original)
      original = remove_markers(original)

      {:ok, selection} = selection_or_line(original, range)

      {_, %Zipper{} = zipper} =
        original
        |> text_to_zipper()
        |> Zipper.traverse_while(nil, fn
          %{node: node} = zipper, _ ->
            if Expert.Refactor.AST.equal?(node, selection),
              do: {:halt, zipper, zipper},
              else: {:cont, zipper, nil}
        end)

      zipper
    end
  end
end
