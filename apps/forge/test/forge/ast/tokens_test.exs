defmodule Forge.Ast.TokensTest do
  use ExUnit.Case, async: true

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  alias Forge.Ast.Tokens

  describe "prefix_stream/2" do
    test "works as intended" do
      text = ~q[
        defmodule Foo do
          def bar do
            |
          end
        end
      ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:eol, ~c"\n", []},
               {:operator, :do, {2, 11}},
               {:do_identifier, ~c"bar", {2, 7}},
               {:identifier, ~c"def", {2, 3}},
               {:eol, ~c"\n", []},
               {:operator, :do, {1, 15}},
               {:alias, ~c"Foo", {1, 11}},
               {:identifier, ~c"defmodule", {1, 1}}
             ]
    end

    test "does not crash on mixed-script identifiers" do
      {position, document} = pop_cursor("# сx|", as: :document)

      assert Enum.to_list(Tokens.prefix_stream(document, position)) != nil

      {position, document} = pop_cursor("defmodule Foo do\n  сx|\nend", as: :document)

      assert Enum.to_list(Tokens.prefix_stream(document, position)) != nil
    end

    test "returns nothing when cursor is at start" do
      text = ~q[
        |defmodule Foo do
          def bar do
            :bar
          end
        end
      ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == []
    end

    test "works on empty interpolations" do
      text = ~S|"foo#{}bar"|

      {position, document} = pop_cursor(text <> "|", as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {
                 :interpolated_string,
                 [
                   {:literal, "foo", {{1, 1}, {1, 4}}},
                   {:interpolation, [], {{1, 7}, {1, 7}}},
                   {:literal, "bar", {{1, 7}, {1, 10}}}
                 ],
                 {1, 1}
               }
             ]
    end

    test "works on interpolations with newlines" do
      text = ~S[
          ~S"""
          "foo«#{
            2
          }»bar"
          """
          |
          ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {
                 :interpolated_string,
                 [
                   {:literal, "foo«", {{1, 1}, {1, 5}}},
                   {:interpolation,
                    [{:eol, {3, 18, 1}}, {:int, {4, 13, 2}, ~c"2"}, {:eol, {4, 14, 1}}],
                    {{3, 18}, {5, 11}}},
                   {:literal, "»bar", {{5, 11}, {5, 15}}}
                 ],
                 {3, 11}
               },
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []}
             ]
    end

    test "handles interpolations starting with parentheses" do
      text = ~S'"foo#{(a && b)}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:"(", {1, 7, nil}},
                     {:identifier, {1, 8, ~c"a"}, :a},
                     {:and_op, {1, 10, nil}, :&&},
                     {:identifier, {1, 13, ~c"b"}, :b},
                     {:")", {1, 14, nil}}
                   ], {{1, 7}, {1, 15}}}
                ], {1, 1}}
             ]
    end

    test "handles interpolations starting with list literal" do
      text = ~S'"foo#{[a, b, c]}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:"[", {1, 7, nil}},
                     {:identifier, {1, 8, ~c"a"}, :a},
                     {:",", {1, 9, 0}},
                     {:identifier, {1, 11, ~c"b"}, :b},
                     {:",", {1, 12, 0}},
                     {:identifier, {1, 14, ~c"c"}, :c},
                     {:"]", {1, 15, nil}}
                   ], {{1, 7}, {1, 16}}}
                ], {1, 1}}
             ]
    end

    test "handles interpolations starting with tuple literal" do
      text = ~S'"foo#{{:ok, value}}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:"{", {1, 7, nil}},
                     {:atom, {1, 8, ~c"ok"}, :ok},
                     {:",", {1, 11, 0}},
                     {:identifier, {1, 13, ~c"value"}, :value},
                     {:"}", {1, 18, nil}}
                   ], {{1, 7}, {1, 19}}}
                ], {1, 1}}
             ]
    end

    test "handles interpolations starting with map literal" do
      text = ~S'"foo#{%{key: value}}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:%{}, {1, 7, nil}},
                     {:"{", {1, curly_column, nil}},
                     {:kw_identifier, {1, 9, ~c"key"}, :key},
                     {:identifier, {1, 14, ~c"value"}, :value},
                     {:"}", {1, 19, nil}}
                   ], {{1, 7}, {1, 20}}}
                ], {1, 1}}
             ] = Enum.to_list(tokens)

      # Elixir < 1.17 reports the `{` of `%{` at column 8, 1.17+ at column 7
      assert curly_column in [7, 8]
    end

    test "handles interpolations starting with struct literal" do
      text = ~S'"foo#{%MyStruct{field: value}}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:%, {1, 7, nil}},
                     {:alias, {1, 8, ~c"MyStruct"}, :MyStruct},
                     {:"{", {1, 16, nil}},
                     {:kw_identifier, {1, 17, ~c"field"}, :field},
                     {:identifier, {1, 24, ~c"value"}, :value},
                     {:"}", {1, 29, nil}}
                   ], {{1, 7}, {1, 30}}}
                ], {1, 1}}
             ]
    end

    test "handles interpolations starting with bitstring literal" do
      text = ~S'"foo#{<<letter>>}"|'

      {position, document} = pop_cursor(text, as: :document)
      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:interpolated_string,
                [
                  {:literal, "foo", {{1, 1}, {1, 4}}},
                  {:interpolation,
                   [
                     {:"<<", {1, 7, nil}},
                     {:identifier, {1, 9, ~c"letter"}, :letter},
                     {:">>", {1, 15, nil}}
                   ], {{1, 7}, {1, 17}}}
                ], {1, 1}}
             ]
    end
  end
end
