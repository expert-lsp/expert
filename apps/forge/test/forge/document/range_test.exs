defmodule Forge.Document.RangeTest do
  use ExUnit.Case, async: true

  import Forge.Document.Line

  alias Forge.Document.Lines
  alias Forge.Document.Position
  alias Forge.Document.Range

  describe "contains?/2" do
    test "includes the start position" do
      range = Range.new(position(1, 1), position(2, 1))
      assert Range.contains?(range, position(1, 1))
    end

    test "excludes the end position" do
      range = Range.new(position(1, 1), position(2, 1))
      refute Range.contains?(range, position(2, 1))
    end

    test "includes position after start character of starting line" do
      range = Range.new(position(1, 1), position(2, 1))
      assert Range.contains?(range, position(1, 2))
    end

    test "includes position before end character of ending line" do
      range = Range.new(position(1, 1), position(2, 2))
      assert Range.contains?(range, position(2, 1))
    end

    test "includes position within lines" do
      range = Range.new(position(1, 3), position(3, 1))
      assert Range.contains?(range, position(2, 2))
    end

    test "excludes position on a different line" do
      range = Range.new(position(1, 1), position(3, 3))
      refute Range.contains?(range, position(4, 1))
    end

    test "excludes position before start character of starting line" do
      range = Range.new(position(1, 2), position(2, 1))
      refute Range.contains?(range, position(1, 1))
    end

    test "excludes position after end character of ending line" do
      range = Range.new(position(1, 1), position(2, 1))
      refute Range.contains?(range, position(2, 2))
    end

    test "excludes the end position of a single-line range" do
      range = Range.new(position(1, 1), position(1, 4))

      refute Range.contains?(range, position(1, 4))
    end
  end

  describe "contains_cursor?/2" do
    test "includes both boundaries and the interior, but excludes outside positions" do
      for range <- [
            Range.new(position(1, 2), position(1, 5)),
            Range.new(position(1, 2), position(2, 5))
          ] do
        assert Range.contains_cursor?(range, range.start)
        assert Range.contains_cursor?(range, position(1, 3))
        assert Range.contains_cursor?(range, range.end)

        refute Range.contains_cursor?(range, position(1, 1))

        refute Range.contains_cursor?(
                 range,
                 position(range.end.line, range.end.character + 1)
               )
      end
    end

    test "an empty range matches only its position" do
      range = Range.new(position(1, 2), position(1, 2))

      assert Range.contains_cursor?(range, position(1, 2))
      refute Range.contains_cursor?(range, position(1, 1))
      refute Range.contains_cursor?(range, position(1, 3))
    end
  end

  defp position(line, character) do
    stub_line = line(text: "", ending: "\n", line_number: line, ascii?: true)

    lines =
      line
      |> empty_lines()
      |> put_in([Access.key(:lines), Access.elem(line - 1)], stub_line)

    Position.new(lines, line, character)
  end

  defp empty_lines(length) do
    tuple = List.to_tuple(for(x <- 1..length, do: x))
    %Lines{lines: tuple, starting_index: 1}
  end
end
