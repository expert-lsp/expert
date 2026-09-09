defmodule Forge.Ast.SelectionRangesTest do
  use ExUnit.Case

  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  describe "ranges/2" do
    test "returns ranges for nested function calls" do
      document = Document.new("file:///selection.ex", "outer(inner(value))", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 15)

      assert ranges(analysis, [position]) ==
               [
                 [
                   Range.new(Position.new(document, 1, 13), Position.new(document, 1, 18)),
                   Range.new(Position.new(document, 1, 12), Position.new(document, 1, 19)),
                   Range.new(Position.new(document, 1, 7), Position.new(document, 1, 19)),
                   Range.new(Position.new(document, 1, 6), Position.new(document, 1, 20)),
                   Range.new(Position.new(document, 1, 1), Position.new(document, 1, 20))
                 ]
               ]
    end

    test "returns the document range when no syntax contains the position" do
      document = Document.new("file:///selection.ex", "   ", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 2)

      assert ranges(analysis, [position]) == [
               [Range.new(Position.new(document, 1, 1), Position.new(document, 1, 4))]
             ]
    end

    test "does not repeat ranges from AST wrappers" do
      document = Document.new("file:///selection.ex", "[value]", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 4)

      assert ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 2), Position.new(document, 1, 7)),
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 8))
               ]
             ]
    end

    test "supports parentheses blocks" do
      document = Document.new("file:///selection.ex", "(value)", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 4)

      assert ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 2), Position.new(document, 1, 7)),
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 8))
               ]
             ]
    end

    test "selects the group when the cursor is on its opening parenthesis" do
      document = Document.new("file:///selection.ex", "(value)", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 1)

      assert ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 8))
               ]
             ]
    end

    test "puts the sorter range first when starts are equal" do
      document = Document.new("file:///selection.ex", "value + other", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 3)

      assert ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 6)),
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 14))
               ]
             ]
    end

    test "selects the inner expression at its end boundary" do
      document = Document.new("file:///selection.ex", "(value)", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 7)

      assert ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 2), Position.new(document, 1, 7)),
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 8))
               ]
             ]
    end

    test "preserves cursor order and duplicate positions" do
      document = Document.new("file:///selection.ex", "outer(inner(value))", 1)
      analysis = Ast.analyze(document)

      inside_value = Position.new(document, 1, 15)
      inside_outer_name = Position.new(document, 1, 3)

      value_range =
        Range.new(Position.new(document, 1, 13), Position.new(document, 1, 18))

      inner_range =
        Range.new(Position.new(document, 1, 7), Position.new(document, 1, 19))

      outer_range =
        Range.new(Position.new(document, 1, 1), Position.new(document, 1, 20))

      outer_name_range =
        Range.new(Position.new(document, 1, 1), Position.new(document, 1, 6))

      inner_parens_range =
        Range.new(Position.new(document, 1, 12), Position.new(document, 1, 19))

      outer_parens_range =
        Range.new(Position.new(document, 1, 6), Position.new(document, 1, 20))

      value_selections = [
        value_range,
        inner_parens_range,
        inner_range,
        outer_parens_range,
        outer_range
      ]

      assert ranges(analysis, [inside_value, inside_outer_name, inside_value]) ==
               [
                 value_selections,
                 [outer_name_range, outer_range],
                 value_selections
               ]
    end

    test "visits a block body when any requested cursor is iside it" do
      for call <- ["custom", "Mod.custom"] do
        source = """
        #{call}(argument) do
          inner(value)
        end
        """

        document = Document.new("file:///selection.ex", source, 1)
        analysis = Ast.analyze(document)

        argument_start = String.length(call) + 2
        argument_position = Position.new(document, 1, argument_start + 1)
        value_position = Position.new(document, 2, 11)

        argument_range =
          Range.new(
            Position.new(document, 1, argument_start),
            Position.new(document, 1, argument_start + String.length("argument"))
          )

        value_range =
          Range.new(Position.new(document, 2, 9), Position.new(document, 2, 14))

        assert [[^argument_range | _], [^value_range | _]] =
                 ranges(analysis, [argument_position, value_position])
      end
    end

    test "recovered ranges form an enclosing chain" do
      document = Document.new("file:///selection.ex", "[value", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 2)

      refute analysis.valid?
      assert [ranges] = ranges(analysis, [position])
      assert [first | _] = ranges

      assert first ==
               Range.new(Position.new(document, 1, 2), Position.new(document, 1, 7))

      for [child, parent] <- Enum.chunk_every(ranges, 2, 1, :discard) do
        assert Position.compare(parent.start, child.start) != :gt
        assert Position.compare(child.end, parent.end) != :gt
      end
    end

    test "inline comment" do
      document = Document.new("file:///selection.ex", "value # hello", 1)

      analysis = Ast.analyze(document)

      comment_position = Position.new(document, 1, 10)
      value_position = Position.new(document, 1, 3)

      expected_selection =
        Range.new(Position.new(document, 1, 9), Position.new(document, 1, 14))

      full_range =
        Range.new(Position.new(document, 1, 1), Position.new(document, 1, 14))

      value_range =
        Range.new(Position.new(document, 1, 1), Position.new(document, 1, 6))

      assert [[^expected_selection, ^full_range], [^value_range, ^full_range]] =
               ranges(analysis, [comment_position, value_position])
    end

    # ElixirLS selection_ranges_test.exs at 68df44b681ee0dbef91b8008b0354003a9a451fa,
    # "brackets nested cursor inside" and "brackets cursor inside right" (one-based here).
    test "includes nested delimiter interiors and the whole document" do
      coordinates = selection_coordinates("[{1, 2}, 3]\n", 1, 4)

      for expected <- [
            {{1, 1}, {2, 1}},
            {{1, 1}, {1, 12}},
            {{1, 2}, {1, 11}},
            {{1, 2}, {1, 8}},
            {{1, 3}, {1, 7}}
          ] do
        assert expected in coordinates
      end
    end

    test "includes the tuple interior at its closing boundary" do
      coordinates = selection_coordinates("{1, 2}\n", 1, 6)

      for expected <- [
            {{1, 1}, {2, 1}},
            {{1, 1}, {1, 7}},
            {{1, 2}, {1, 6}}
          ] do
        assert expected in coordinates
      end
    end

    test "includes the correct document range for each line ending" do
      for {source, expected_end} <- [
            {"", {1, 1}},
            {"value", {1, 6}},
            {"value\n", {2, 1}},
            {"value\r\n", {2, 1}},
            {"value\r", {2, 1}}
          ] do
        coordinates = selection_coordinates(source, 1, 1)

        assert {{1, 1}, expected_end} in coordinates
      end
    end

    test "includes the full line for a standalone comment" do
      coordinates = selection_coordinates("  # some comment\n", 1, 6)

      for expected <- [
            {{1, 1}, {2, 1}},
            {{1, 1}, {1, 17}},
            {{1, 3}, {1, 17}}
          ] do
        assert expected in coordinates
      end
    end

    test "expands comments on the first, middle, and last lines of a block" do
      source = """
        # some comment
        # continues here
        # ends here
      """

      block_ranges = [
        {{1, 1}, {4, 1}},
        {{1, 1}, {3, 14}},
        {{1, 3}, {3, 14}}
      ]

      for {cursor_line, line_ranges} <- [
            {1, [{{1, 3}, {1, 17}}]},
            {2, [{{2, 1}, {2, 19}}, {{2, 3}, {2, 19}}]},
            {3, [{{3, 1}, {3, 14}}, {{3, 3}, {3, 14}}]}
          ] do
        coordinates = selection_coordinates(source, cursor_line, 6)

        for expected <- block_ranges ++ line_ranges do
          assert expected in coordinates
        end
      end
    end

    test "does not group comments across blank lines or inline comments" do
      for source <- [
            """
              # first

              # second
            """,
            """
              # first
              value # inline
              # second
            """
          ] do
        coordinates = selection_coordinates(source, 3, 6)

        assert {{3, 3}, {3, 11}} in coordinates
        refute {{1, 3}, {3, 11}} in coordinates
        refute {{1, 1}, {3, 11}} in coordinates
      end
    end

    test "includes indented body lines with and without leading indentation" do
      source = """
      %My.Struct{
        some: 123,
        other: "abc"
      }
      """

      coordinates = selection_coordinates(source, 2, 3)

      assert {{2, 1}, {3, 15}} in coordinates
      assert {{2, 3}, {3, 15}} in coordinates
    end

    test "includes indentation selections across case clauses" do
      source =
        """
        case foo do
          {:ok, _} -> :ok
          _ ->
            Logger.error("Foo")
            :error
        end
        """

      coordinates = selection_coordinates(source, 2, 17)

      assert {{2, 1}, {5, 11}} in coordinates
      assert {{2, 3}, {5, 11}} in coordinates
    end

    test "body followed by a blank line" do
      coordinates =
        selection_coordinates(
          """
          foo do
            value

          end
          """,
          2,
          4
        )

      assert {{2, 1}, {2, 8}} in coordinates
      assert {{2, 1}, {3, 1}} in coordinates
    end

    test "selects the qualified function name separately from its arguments" do
      coordinates =
        selection_coordinates("Some.Module.Foo.some_fun()\n", 1, 18)

      assert {{1, 1}, {1, 25}} in coordinates
      assert {{1, 1}, {1, 27}} in coordinates
      assert {{1, 1}, {2, 1}} in coordinates
    end

    test "selects the struct name separately from its fields" do
      source = """
      %My.Struct{
        some: 123,
        other: "abc"
      }
      """

      coordinates = selection_coordinates(source, 1, 3)

      assert {{1, 2}, {1, 11}} in coordinates
      assert {{1, 1}, {1, 11}} in coordinates
      assert {{1, 1}, {4, 2}} in coordinates
      assert {{1, 1}, {5, 1}} in coordinates
    end

    test "selects the code between do and else" do
      source = """
      if a + b > 1 do
        :ok
      else
        :error
      end
      """

      coordinates = selection_coordinates(source, 2, 3)

      assert {{2, 3}, {2, 6}} in coordinates
      assert {{1, 16}, {3, 1}} in coordinates
      assert {{1, 1}, {5, 4}} in coordinates
      assert {{1, 1}, {6, 1}} in coordinates
    end

    test "selects function arguments with and without parentheses" do
      source = "fun(%My{} = my, keyword: 123, other: [:a, \"\"])\n"

      for {column, argument_range} <- [
            {7, {{1, 5}, {1, 15}}},
            {19, {{1, 17}, {1, 29}}},
            {32, {{1, 31}, {1, 46}}}
          ] do
        coordinates = selection_coordinates(source, 1, column)

        for expected <- [
              {{1, 1}, {2, 1}},
              {{1, 1}, {1, 47}},
              {{1, 4}, {1, 47}},
              {{1, 5}, {1, 46}},
              argument_range
            ] do
          assert expected in coordinates
        end
      end
    end

    test "selects arguments across multiple lines" do
      source = """
      fun(
        first,
        second
      )
      """

      coordinates = selection_coordinates(source, 2, 4)

      assert {{1, 4}, {4, 2}} in coordinates
      assert {{1, 5}, {4, 1}} in coordinates
    end

    test "selects the brackets around an access key" do
      coordinates = selection_coordinates("map[key]\n", 1, 5)

      assert {{1, 5}, {1, 8}} in coordinates
      assert {{1, 4}, {1, 9}} in coordinates
      assert {{1, 1}, {2, 1}} in coordinates
    end

    test "handles every cursor position in chained bracket access" do
      source = "foo[bar][baz]\n"

      for column <- 1..14 do
        coordinates = selection_coordinates(source, 1, column)

        assert [{start, finish} | _] = coordinates
        assert start <= {1, column}
        assert {1, column} <= finish

        for [{child_start, child_end}, {parent_start, parent_end}] <-
              Enum.chunk_every(coordinates, 2, 1, :discard) do
          assert parent_start <= child_start
          assert child_end <= parent_end
        end
      end
    end

    test "keeps selections nested around every cursor across block sections and adjacent brackets" do
      source = """
      try do
        foo[bar][baz]
      rescue
        e -> e
      after
        cleanup()
      end
      """

      for {text, line} <- source |> String.split("\n") |> Enum.with_index(1),
          column <- 1..(String.length(text) + 1) do
        assert_selections(source, {line, column}, [{{1, 1}, {8, 1}}])
      end
    end

    test "keeps selections nested around every cursor in an incomplete block" do
      source = """
      if ready? do
        foo[bar][baz]
      else
        outer(value
      """

      document = Document.new("file:///selection.ex", source, 1)
      refute Ast.analyze(document).valid?

      for {text, line} <- source |> String.split("\n") |> Enum.with_index(1),
          column <- 1..(String.length(text) + 1) do
        assert_selections(source, {line, column}, [{{1, 1}, {5, 1}}])
      end
    end

    test "selects true, false, and nil without extra characters" do
      for literal <- ["true", "false", "nil"] do
        coordinates = selection_coordinates(literal <> "\n", 1, 2)

        assert coordinates == [
                 {{1, 1}, {1, String.length(literal) + 1}},
                 {{1, 1}, {2, 1}}
               ]
      end
    end

    test "includes the colon when selecting atoms" do
      for literal <- [":ok", ":true", ":false", ":nil"] do
        coordinates = selection_coordinates(literal <> "\n", 1, 2)

        assert coordinates == [
                 {{1, 1}, {1, String.length(literal) + 1}},
                 {{1, 1}, {2, 1}}
               ]
      end
    end
  end

  describe "native range order" do
    test "returns the document first and the smallest expression last" do
      document = Document.new("file:///selection.ex", "outer(value)", 1)
      analysis = Ast.analyze(document)
      position = Position.new(document, 1, 8)

      assert Ast.SelectionRanges.ranges(analysis, [position]) == [
               [
                 Range.new(Position.new(document, 1, 1), Position.new(document, 1, 13)),
                 Range.new(Position.new(document, 1, 6), Position.new(document, 1, 13)),
                 Range.new(Position.new(document, 1, 7), Position.new(document, 1, 12))
               ]
             ]
    end
  end

  describe "expression selections" do
    test "selects a qualified alias" do
      assert_selections("Some.Module.Foo\n", {1, 2}, [
        {{1, 1}, {1, 16}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects a tuple interior at its left boundary" do
      assert_selections("{1, 2}\n", {1, 2}, [
        {{1, 2}, {1, 6}},
        {{1, 1}, {1, 7}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects a tuple at its opening delimiter" do
      assert selection_coordinates("{1, 2}\n", 1, 1) == [
               {{1, 1}, {1, 7}},
               {{1, 1}, {2, 1}}
             ]
    end

    test "selects a number within an arithmetic expression" do
      assert_selections("1234 + 43\n", {1, 1}, [
        {{1, 1}, {1, 5}},
        {{1, 1}, {1, 10}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "preserves operator precedence" do
      assert_selections("var1 + var2 * var3 > var4 - var5\n", {1, 9}, [
        {{1, 8}, {1, 12}},
        {{1, 8}, {1, 19}},
        {{1, 1}, {1, 19}},
        {{1, 1}, {1, 33}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects each group with and without parentheses" do
      assert_selections("1 + (2 * (3 + (s + x)) / 1)\n", {1, 16}, [
        {{1, 16}, {1, 17}},
        {{1, 16}, {1, 21}},
        {{1, 15}, {1, 22}},
        {{1, 11}, {1, 22}},
        {{1, 10}, {1, 23}},
        {{1, 6}, {1, 27}},
        {{1, 5}, {1, 28}},
        {{1, 1}, {1, 28}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects the complete not-in expression" do
      assert_selections("value not in [1, 2]\n", {1, 9}, [
        {{1, 1}, {1, 20}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects a struct field and both brace ranges" do
      source = "%My.Struct{\n  some: 123,\n  other: \"abc\"\n}\n"

      assert_selections(source, {2, 3}, [
        {{2, 3}, {2, 7}},
        {{2, 3}, {2, 12}},
        {{1, 12}, {4, 1}},
        {{1, 11}, {4, 2}},
        {{1, 1}, {4, 2}},
        {{1, 1}, {5, 1}}
      ])
    end

    test "selects a keyword list within a call" do
      assert_selections("my(1, a: 2, b: 3)\n", {1, 7}, [
        {{1, 7}, {1, 17}},
        {{1, 1}, {1, 18}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects a multiline keyword list and its key-value pair" do
      assert_selections("my(1, a: 2,\n  b: 3,\n  c: 4\n)\n", {2, 3}, [
        {{2, 3}, {2, 5}},
        {{2, 3}, {2, 7}},
        {{1, 7}, {3, 7}},
        {{1, 1}, {4, 2}},
        {{1, 1}, {5, 1}}
      ])
    end

    test "selects the source map in an update" do
      assert_selections("%{asd | a: 1, b: x}\n", {1, 4}, [
        {{1, 3}, {1, 6}},
        {{1, 1}, {1, 20}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects the updated fields and a key-value pair" do
      assert_selections("%{asd | a: 1, b: x}\n", {1, 10}, [
        {{1, 9}, {1, 13}},
        {{1, 9}, {1, 19}},
        {{1, 1}, {1, 20}},
        {{1, 1}, {2, 1}}
      ])
    end

    test "selects the map update operator at its left boundary" do
      source = "%{state | 1 => 1, counter: counter + to_dispatch, demand: demand - to_dispatch}\n"
      assert_selections(source, {1, 9}, [{{1, 9}, {1, 10}}, {{1, 1}, {1, 80}}])
    end

    test "selects the map update expression at the operator's right boundary" do
      source = "%{state | 1 => 1, counter: counter + to_dispatch, demand: demand - to_dispatch}\n"
      assert_selections(source, {1, 10}, [{{1, 3}, {1, 79}}, {{1, 1}, {1, 80}}])
    end

    test "selects arguments of a quoted remote call" do
      assert_selections(~s|Mod."odd name"(value)\n|, {1, 17}, [
        {{1, 16}, {1, 21}},
        {{1, 15}, {1, 22}},
        {{1, 1}, {1, 22}}
      ])
    end

    test "selects arguments after an escaped quote in a remote name" do
      assert_selections("Mod.\"odd\\\"name\"(value)\n", {1, 18}, [
        {{1, 17}, {1, 22}},
        {{1, 16}, {1, 23}},
        {{1, 1}, {1, 23}}
      ])
    end

    test "selects arguments of an anonymous invocation" do
      assert_selections("fun.(value)\n", {1, 7}, [
        {{1, 6}, {1, 11}},
        {{1, 5}, {1, 12}},
        {{1, 1}, {1, 12}}
      ])
    end

    test "selects a bitstring with and without its delimiters" do
      assert_selections("<<value, other>>\n", {1, 5}, [
        {{1, 3}, {1, 8}},
        {{1, 3}, {1, 15}},
        {{1, 1}, {1, 17}},
        {{1, 1}, {2, 1}}
      ])
    end
  end

  describe "strings and documentation" do
    test "selects a documentation sigil and its attribute" do
      assert_selections(~s(@doc ~S"""\nThis is a doc\n"""\n), {2, 1}, [
        {{1, 1}, {3, 4}},
        {{1, 1}, {4, 1}}
      ])
    end

    test "selects a documentation heredoc and its attribute" do
      assert_selections(~s(@doc """\nThis is a doc\n"""\n), {2, 1}, [
        {{1, 1}, {3, 4}},
        {{1, 1}, {4, 1}}
      ])
    end

    test "selects a documentation charlist and its attribute" do
      assert_selections("@doc '''\nThis is a doc\n'''\n", {2, 1}, [
        {{1, 1}, {3, 4}},
        {{1, 1}, {4, 1}}
      ])
    end

    test "selects a heredoc with an indented opening delimiter" do
      assert_selections(~s(  """\nThis is a doc\n"""\n), {2, 1}, [
        {{1, 3}, {3, 4}},
        {{1, 1}, {4, 1}}
      ])
    end

    test "selects interpolation contents and the whole string" do
      assert_selections(~S|"asdf#{inspect([1, 2])}gfds"| <> "\n", {1, 18}, [
        {{1, 17}, {1, 18}},
        {{1, 16}, {1, 22}},
        {{1, 8}, {1, 23}},
        {{1, 6}, {1, 24}},
        {{1, 1}, {1, 29}},
        {{1, 1}, {2, 1}}
      ])
    end
  end

  describe "blocks and clauses" do
    test "selects an incomplete bare do-end block" do
      assert_selections("do\n  1\n  24\nend\n", {2, 2}, [
        {{2, 1}, {3, 5}},
        {{1, 1}, {4, 4}},
        {{1, 1}, {5, 1}}
      ])
    end

    test "selects do at its left boundary in a recovered block" do
      assert_selections("do\n  1\n  24\nend\n", {1, 1}, [
        {{1, 1}, {1, 3}},
        {{1, 1}, {4, 4}}
      ])
    end

    test "selects a recovered block at the right boundary of do" do
      assert_selections("do\n  1\n  24\nend\n", {1, 3}, [{{1, 1}, {4, 4}}])
    end

    test "selects end at its left boundary in a recovered block" do
      assert_selections("do\n  1\n  24\nend\n", {4, 1}, [
        {{4, 1}, {4, 4}},
        {{1, 1}, {4, 4}}
      ])
    end

    test "selects a recovered block at the right boundary of end" do
      assert_selections("do\n  1\n  24\nend\n", {4, 4}, [{{1, 1}, {4, 4}}])
    end

    test "selects nested function and module definitions" do
      source = "defmodule Abc do\n  def some() do\n    :ok\n  end\nend\n"

      assert_selections(source, {3, 5}, [
        {{2, 3}, {4, 6}},
        {{1, 1}, {5, 4}},
        {{1, 1}, {6, 1}}
      ])
    end

    test "selects a case argument outside the block body" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  _ ->\n    Logger.error(\"Foo\")\n    :error\nend\n"

      assert_selections(source, {1, 7}, [{{1, 6}, {1, 9}}, {{1, 1}, {6, 4}}])
    end

    test "selects the pattern of a single-line clause" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  _ ->\n    Logger.error(\"Foo\")\n    :error\nend\n"

      assert_selections(source, {2, 4}, [
        {{2, 3}, {2, 11}},
        {{2, 3}, {2, 18}},
        {{2, 3}, {5, 11}},
        {{1, 10}, {6, 4}}
      ])
    end

    test "selects the body of a single-line clause" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  _ ->\n    Logger.error(\"Foo\")\n    :error\nend\n"

      assert_selections(source, {2, 17}, [
        {{2, 15}, {2, 18}},
        {{2, 3}, {2, 18}},
        {{2, 3}, {5, 11}},
        {{1, 10}, {6, 4}}
      ])
    end

    test "selects a multiline pattern with its arrow" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  %{\n    asdf: 1\n  } ->\n    Logger.error(\"Foo\")\n    :error\n  _ -> :foo\nend\n"

      assert_selections(source, {4, 6}, [
        {{3, 3}, {5, 4}},
        {{3, 3}, {5, 7}},
        {{3, 3}, {7, 11}},
        {{1, 10}, {9, 4}}
      ])
    end

    test "selects a multiline clause body" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  %{\n    asdf: 1\n  } ->\n    Logger.error(\"Foo\")\n    :error\n  _ -> :foo\nend\n"

      assert_selections(source, {6, 6}, [
        {{6, 5}, {7, 11}},
        {{3, 3}, {7, 11}},
        {{2, 3}, {8, 12}},
        {{1, 10}, {9, 4}}
      ])
    end

    test "selects the final clause in a block" do
      source =
        "case foo do\n  {:ok, _} -> :ok\n  %{\n    asdf: 1\n  } ->\n    Logger.error(\"Foo\")\n    :error\n  _ -> :foo\nend\n"

      assert_selections(source, {8, 9}, [
        {{8, 8}, {8, 12}},
        {{8, 3}, {8, 12}},
        {{2, 3}, {8, 12}},
        {{1, 10}, {9, 4}}
      ])
    end

    test "selects consecutive calls in a clause body" do
      source = "case x do\n  a ->\n    some_fun()\n  b ->\n    more()\n    funs()\nend\n"

      assert_selections(source, {5, 6}, [
        {{5, 5}, {5, 11}},
        {{5, 5}, {6, 11}},
        {{4, 3}, {6, 11}}
      ])
    end

    test "selects an if condition" do
      source = "if a + b > 1 do\n  :ok\nelse\n  :error\nend\n"
      assert_selections(source, {1, 4}, [{{1, 4}, {1, 13}}, {{1, 1}, {5, 4}}])
    end

    test "selects an else branch" do
      source = "if a + b > 1 do\n  :ok\nelse\n  :error\nend\n"
      assert_selections(source, {4, 3}, [{{4, 3}, {4, 9}}, {{3, 1}, {5, 4}}])
    end

    test "selects else at its section boundary" do
      source = "if a do\n  :ok\nelse\n  :error\nend\n"
      assert_selections(source, {3, 1}, [{{3, 1}, {3, 5}}, {{3, 1}, {5, 4}}])
    end

    test "selects else in a single-line block" do
      source = "if a do :ok else :err end\n"
      assert_selections(source, {1, 19}, [{{1, 13}, {1, 26}}, {{1, 1}, {1, 26}}])
    end

    test "selects the else section in with" do
      source = "with {:ok, x} <- foo() do\n  x\nelse\n  e -> e\nend\n"
      assert_selections(source, {3, 1}, [{{3, 1}, {3, 5}}, {{3, 1}, {5, 4}}])
    end

    test "selects rescue, catch, else, and after sections of try" do
      source =
        "try do\n  work()\nrescue\n  e -> e\ncatch\n  :exit, e -> e\nelse\n  x -> x\nafter\n  cleanup()\nend\n"

      for {line, keyword_end, section_end} <- [
            {3, 7, {5, 1}},
            {5, 6, {7, 1}},
            {7, 5, {9, 1}},
            {9, 6, {11, 4}}
          ] do
        assert_selections(source, {line, 1}, [
          {{line, 1}, {line, keyword_end}},
          {{line, 1}, section_end},
          {{1, 1}, {11, 4}}
        ])
      end
    end

    test "selects a rescue body up to catch" do
      source = "try do\n  work()\nrescue\n  e -> e\ncatch\n  :exit, e -> e\nend\n"
      assert_selections(source, {4, 8}, [{{4, 3}, {4, 9}}, {{3, 7}, {5, 1}}])
    end

    test "selects an empty block without inverted ranges" do
      assert_selections("if 1 do\n\nend\n", {2, 1}, [
        {{1, 6}, {3, 4}},
        {{1, 1}, {3, 4}},
        {{1, 1}, {4, 1}}
      ])
    end
  end

  describe "for and with" do
    test "selects a for block body" do
      source = "for x <- [1, 2, 3], y <- [4, 5, 6] do\n  x + y\nend\n"
      assert_selections(source, {2, 3}, [{{2, 3}, {2, 8}}, {{1, 36}, {3, 4}}])
    end

    test "selects a single-line for body and its do key" do
      source = "for x <- [1, 2, 3], y <- [4, 5, 6], into: %{}, do: x + y\n"

      assert_selections(source, {1, 52}, [
        {{1, 52}, {1, 57}},
        {{1, 48}, {1, 57}},
        {{1, 1}, {1, 57}}
      ])
    end

    test "selects a for body on a separate keyword line" do
      source = "for x <- [1, 2, 3], y <- [4, 5, 6],\n  into: %{},\n  do: x + y\n"
      assert_selections(source, {3, 7}, [{{3, 7}, {3, 12}}, {{1, 1}, {3, 12}}])
    end

    test "selects a for generator" do
      source = "for x <- [1, 2, 3], y <- [4, 5, 6] do\n  x + y\nend\n"
      assert_selections(source, {1, 11}, [{{1, 10}, {1, 19}}, {{1, 5}, {1, 19}}])
    end

    test "selects a with block body" do
      source = "with x <- [1, 2, 3], y <- [4, 5, 6] do\n  x ++ y\nend\n"
      assert_selections(source, {2, 3}, [{{2, 3}, {2, 9}}, {{1, 37}, {3, 4}}])
    end

    test "selects a single-line with body" do
      source = "with x <- [1, 2, 3], y <- [4, 5, 6], do: x ++ y\n"
      assert_selections(source, {1, 43}, [{{1, 42}, {1, 48}}, {{1, 1}, {1, 48}}])
    end

    test "selects a with body on a separate keyword line" do
      source = "with x <- [1, 2, 3],\n  y <- [4, 5, 6],\n  do: x ++ y\n"
      assert_selections(source, {3, 7}, [{{3, 7}, {3, 13}}, {{1, 1}, {3, 13}}])
    end

    test "selects a with generator" do
      source = "with x <- [1, 2, 3], y <- [4, 5, 6] do\n  x ++ y\nend\n"
      assert_selections(source, {1, 11}, [{{1, 11}, {1, 20}}, {{1, 6}, {1, 20}}])
    end
  end

  defp assert_selections(source, {line, column} = cursor, expected) do
    coordinates = selection_coordinates(source, line, column)

    for range <- expected do
      assert range in coordinates
    end

    for {start, finish} <- coordinates do
      assert start <= cursor
      assert cursor <= finish
    end

    for [{child_start, child_end}, {parent_start, parent_end}] <-
          Enum.chunk_every(coordinates, 2, 1, :discard) do
      assert parent_start <= child_start
      assert child_end <= parent_end
    end
  end

  defp selection_coordinates(source, line, column) do
    document = Document.new("file:///selection.ex", source, 1)
    analysis = Ast.analyze(document)
    position = Position.new(document, line, column)

    assert [ranges] = ranges(analysis, [position])

    for range <- ranges do
      {
        {range.start.line, range.start.character},
        {range.end.line, range.end.character}
      }
    end
  end

  defp ranges(analysis, positions) do
    analysis
    |> Ast.SelectionRanges.ranges(positions)
    |> Enum.map(&Enum.reverse/1)
  end
end
