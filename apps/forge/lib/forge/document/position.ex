defmodule Forge.Document.Position do
  @moduledoc """
  A position inside of a document

  This struct represents a cursor position inside a document, using one-based line and character
  numbers. It's important to note that the position starts before the character given, so positions
  are inclusive of the given character.

  Given the following line of text:
  "Hello there, welcome to Forge"

  the position: `%Forge.Document.Position{line: 1, character: 1}` starts before the "H" in "Hello"
  """

  use Forge.StructAccess

  alias Forge.Document
  alias Forge.Document.Lines

  defstruct [
    :line,
    :character,
    valid?: false,
    context_line: nil,
    document_line_count: 0,
    starting_index: 1,
    # Used to convert positions when the original context_line is not available
    utf16_character: nil
  ]

  @type line :: non_neg_integer()
  @type character :: non_neg_integer()
  @type line_container :: Document.t() | Lines.t()

  @type t :: %__MODULE__{
          character: character(),
          context_line: Document.Line.t() | nil,
          document_line_count: non_neg_integer(),
          line: line(),
          starting_index: non_neg_integer(),
          utf16_character: character() | nil,
          valid?: boolean()
        }

  @spec new(line_container(), line(), character()) :: t
  def new(%Document{} = document, line, character)
      when is_number(line) and is_number(character) do
    new(document.lines, line, character)
  end

  def new(%Document.Lines{} = lines, line, character)
      when is_number(line) and is_number(character) do
    line_count = Document.Lines.size(lines)
    starting_index = lines.starting_index

    case Lines.fetch_line(lines, line) do
      {:ok, context_line} ->
        %__MODULE__{
          character: character,
          context_line: context_line,
          document_line_count: line_count,
          line: line,
          starting_index: starting_index,
          valid?: true
        }

      :error ->
        %__MODULE__{
          line: line,
          character: character,
          document_line_count: line_count,
          starting_index: starting_index
        }
    end
  end

  def new(_, _, _) do
    :error
  end

  @doc """
  Compares two positions.

  Returns `:gt`, `:lt`, or `:eq` depending on the location of the first
  position relative to the second.
  """
  @spec compare(t | {line, character}, t | {line, character}) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = pos1, %__MODULE__{} = pos2) do
    compare({pos1.line, pos1.character}, {pos2.line, pos2.character})
  end

  def compare(%__MODULE__{} = pos1, {_, _} = pos2) do
    compare({pos1.line, pos1.character}, pos2)
  end

  def compare({_, _} = pos1, %__MODULE__{} = pos2) do
    compare(pos1, {pos2.line, pos2.character})
  end

  def compare({l1, c1} = first, {l2, c2} = second)
      when is_integer(l1) and is_integer(c1) and is_integer(l2) and is_integer(c2) do
    cond do
      first < second -> :lt
      first > second -> :gt
      true -> :eq
    end
  end
end

defimpl Inspect, for: Forge.Document.Position do
  import Inspect.Algebra

  def inspect(pos, _) do
    concat(["XpPos", to_string(pos)])
  end
end

defimpl String.Chars, for: Forge.Document.Position do
  def to_string(pos) do
    "<<#{pos.line}, #{pos.character}>>"
  end
end
