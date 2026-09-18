defmodule Forge.Document.Range do
  @moduledoc """
  A range in a document

  Note that ranges represent a cursor position, and so are inclusive of
  lines, but exclusive of the end position.

  Note: To select an entire line, construct a range that runs from the
  first character on the line to the first character on the next line.

  ```
  whole_line =
    Range.new(
      Position.new(doc, 1, 1),
      Position.new(doc, 2, 1)
    )
  ```
  """
  use Forge.StructAccess

  alias Forge.Document.Position

  defstruct start: nil, end: nil

  @type t :: %__MODULE__{
          start: Position.t(),
          end: Position.t()
        }

  @doc """
  Builds a new range.
  """
  def new(%Position{} = start_pos, %Position{} = end_pos) do
    %__MODULE__{start: start_pos, end: end_pos}
  end

  @doc """
  Returns whether the range contains the given position.
  """
  def contains?(%__MODULE__{} = range, %Position{} = position) do
    %__MODULE__{start: start_pos, end: end_pos} = range

    cond do
      position.line == start_pos.line and position.line == end_pos.line ->
        position.character >= start_pos.character and position.character < end_pos.character

      position.line == start_pos.line ->
        position.character >= start_pos.character

      position.line == end_pos.line ->
        position.character < end_pos.character

      true ->
        position.line > start_pos.line and position.line < end_pos.line
    end
  end

  @doc """
  Returns whether the cursor is between the range's start and end, including
  the end position.
  """
  @spec contains_cursor?(t(), Position.t()) :: boolean()
  def contains_cursor?(%__MODULE__{} = range, %Position{} = position) do
    Position.compare(position, range.start) != :lt and
      Position.compare(position, range.end) != :gt
  end
end

defimpl Inspect, for: Forge.Document.Range do
  import Inspect.Algebra

  def inspect(range, _) do
    concat(["XpRange[", to_string(range.start), "...", to_string(range.end), "]"])
  end
end
