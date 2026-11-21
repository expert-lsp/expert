defmodule Forge.Document.Diff do
  @moduledoc """
  Computes the edits that turn a document into the given text.

  The diff is line-based: `List.myers_difference` runs over the documents'
  lines, and each changed region becomes one edit on line boundaries. Lines
  are the unit because character-level Myers over an entire document is
  O(chars x edit distance) and can take minutes on a large, heavily changed
  document; line-level runs in milliseconds and clients apply line-granular
  edits just fine.
  """
  import Forge.Document.Line, only: :macros

  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  @spec diff(Document.t(), String.t()) :: [Edit.t()]
  def diff(%Document{} = document, dest) when is_binary(dest) do
    dest_document = Document.new(document.uri, dest, 0)

    document
    |> normalized_lines()
    |> List.myers_difference(normalized_lines(dest_document))
    |> merge_replacements()
    |> to_edits(document)
  end

  # Myers compares lines with ==, and a line record carries its line number,
  # which differs between the documents once any line shifts. Zeroing it
  # makes lines with the same content compare equal.
  defp normalized_lines(%Document{} = document) do
    Enum.map(document.lines, fn line() = doc_line ->
      line(doc_line, line_number: 0)
    end)
  end

  # A delete immediately followed by an insert is a replacement; merging them
  # emits one edit for the region instead of a delete and an insert.
  defp merge_replacements([{:del, deleted}, {:ins, inserted} | rest]) do
    [{:replace, deleted, inserted} | merge_replacements(rest)]
  end

  defp merge_replacements([operation | rest]) do
    [operation | merge_replacements(rest)]
  end

  defp merge_replacements([]) do
    []
  end

  defp to_edits(operations, %Document{} = document) do
    {_line, edits} =
      Enum.reduce(operations, {starting_line(), []}, fn
        {:eq, lines}, {current_line, edits} ->
          {current_line + length(lines), edits}

        {:del, lines}, {current_line, edits} ->
          end_line = current_line + length(lines)
          edit = edit(document, "", current_line, end_line)
          {end_line, [edit | edits]}

        {:ins, lines}, {current_line, edits} ->
          edit = edit(document, text_of(lines), current_line, current_line)
          {current_line, [edit | edits]}

        {:replace, deleted, inserted}, {current_line, edits} ->
          end_line = current_line + length(deleted)
          edit = edit(document, text_of(inserted), current_line, end_line)
          {end_line, [edit | edits]}
      end)

    # The edits accumulate in reverse document order, which is what
    # sequential application needs: applying back-to-front keeps earlier
    # positions valid as line counts change.
    edits
  end

  defp text_of(lines) do
    lines
    |> Enum.map(fn line(text: text, ending: ending) ->
      [text, ending]
    end)
    |> IO.iodata_to_binary()
  end

  defp edit(document, text, start_line, end_line) when is_binary(text) do
    Edit.new(
      text,
      Range.new(
        Position.new(document, start_line, starting_character()),
        Position.new(document, end_line, starting_character())
      )
    )
  end

  defp starting_line, do: 1
  defp starting_character, do: 1
end
