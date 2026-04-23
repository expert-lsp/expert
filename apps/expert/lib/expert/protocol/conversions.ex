defmodule Expert.Protocol.Conversions do
  @moduledoc """
  Functions to convert between language server representations and elixir-native representations.

  The LSP protocol defines positions in terms of their utf-16 representation (thanks, windows),
  so when a document change comes in, we need to recalculate the positions of the change if
  the line contains non-ascii characters. If it's a pure ascii line, then the positions
  are the same in both utf-8 and utf-16, since they reference characters and not bytes.
  """
  import Forge.Document.Line

  alias Forge.CodeUnit
  alias Forge.Document
  alias Forge.Document.Lines
  alias Forge.Document.Position, as: ElixirPosition
  alias Forge.Document.Range, as: ElixirRange
  alias Forge.Math
  alias GenLSP.Structures.Position, as: LSPosition
  alias GenLSP.Structures.Range, as: LSRange

  def to_elixir(%LSRange{} = ls_range, %Document{} = doc) do
    with {:ok, start_pos} <- to_elixir(ls_range.start, doc.lines),
         {:ok, end_pos} <- to_elixir(ls_range.end, doc.lines) do
      {:ok, %ElixirRange{start: start_pos, end: end_pos}}
    else
      _ ->
        {:error, {:invalid_range, ls_range}}
    end
  end

  def to_elixir(%LSRange{}, nil) do
    {:error, {:invalid_document, nil}}
  end

  def to_elixir(%ElixirPosition{} = position, _) do
    {:ok, position}
  end

  def to_elixir(%LSPosition{} = position, %Document{} = document) do
    to_elixir(position, document.lines)
  end

  def to_elixir(%LSPosition{line: line} = position, _) when line < 0 do
    {:error, {:invalid_position, position}}
  end

  def to_elixir(%LSPosition{}, nil) do
    {:error, {:invalid_document, nil}}
  end

  def to_elixir(%LSPosition{} = position, %Lines{} = lines) do
    line_count = Lines.size(lines)
    # we need to handle out of bounds line numbers, because it's possible to build a document
    # by starting with an empty document and appending to the beginning of it, with a start range of
    # {0, 0} and and end range of {1, 0} (replace the first line)
    document_line_number = Math.clamp(position.line, 0, line_count) + lines.starting_index
    ls_character = position.character

    cond do
      document_line_number == line_count and ls_character == 0 ->
        # allow a line one more than the document size, as long as the character is 0.
        # that means we're operating on the last line of the document
        {:ok, ElixirPosition.new(lines, document_line_number, 1)}

      position.line >= line_count ->
        # they've specified something outside of the document clamp it down so they can append at the
        # end
        {:ok, ElixirPosition.new(lines, document_line_number, 1)}

      true ->
        with {:ok, line} <- Lines.fetch_line(lines, document_line_number),
             {:ok, elixir_character} <- extract_elixir_character(position, line) do
          {:ok, ElixirPosition.new(lines, document_line_number, elixir_character)}
        end
    end
  end

  def to_elixir(%{range: %{start: start_pos, end: end_pos}}, %Document{} = document) do
    # this is actually an elixir sense range... note that it's a bare map with
    # column keys rather than character keys.
    %{line: start_line, column: start_col} = start_pos
    %{line: end_line, column: end_col} = end_pos

    range =
      ElixirRange.new(
        ElixirPosition.new(document, start_line, start_col),
        ElixirPosition.new(document, end_line, end_col)
      )

    {:ok, range}
  end

  def to_elixir(%{range: %{start: _start_pos, end: _end_pos}}, nil) do
    {:error, {:invalid_document, nil}}
  end

  def to_lsp(%LSRange{start: %LSPosition{}, end: %LSPosition{}} = ls_range) do
    {:ok, ls_range}
  end

  def to_lsp(%LSRange{} = ls_range) do
    with {:ok, start_pos} <- to_lsp(ls_range.start),
         {:ok, end_pos} <- to_lsp(ls_range.end) do
      {:ok, %LSRange{start: start_pos, end: end_pos}}
    end
  end

  def to_lsp(%ElixirRange{} = ex_range) do
    with {:ok, start_pos} <- to_lsp(ex_range.start),
         {:ok, end_pos} <- to_lsp(ex_range.end) do
      {:ok, %LSRange{start: start_pos, end: end_pos}}
    end
  end

  def to_lsp(%ElixirPosition{} = position) do
    elixir_character = position.character
    line_count = position.document_line_count
    document_line_number = Math.clamp(position.line, 1, line_count)

    cond do
      position.line == line_count + 1 and elixir_character == 1 ->
        # allow a line one more than the document size, as long as the character is 0.
        # that means we're operating on the last line of the document

        {:ok, %LSPosition{line: document_line_number, character: 0}}

      position.line > line_count ->
        {:ok, %LSPosition{line: line_count, character: 0}}

      true ->
        with {:ok, lsp_character} <- extract_lsp_character(position) do
          ls_pos =
            %LSPosition{
              character: lsp_character,
              line: position.line - position.starting_index
            }

          {:ok, ls_pos}
        end
    end
  end

  def to_lsp(%LSPosition{} = position) do
    {:ok, position}
  end

  # Private

  defp extract_lsp_character(
         %ElixirPosition{context_line: line(ascii?: true, text: text)} = position
       ) do
    character = min(position.character - 1, byte_size(text))
    {:ok, character}
  end

  defp extract_lsp_character(%ElixirPosition{context_line: line(text: utf8_text)} = position) do
    code_unit = CodeUnit.utf8_position_to_utf16_offset(utf8_text, position.character - 1)
    character = min(code_unit, CodeUnit.count(:utf16, utf8_text))
    {:ok, character}
  end

  defp extract_elixir_character(%LSPosition{} = position, line(ascii?: true)) do
    {:ok, position.character + 1}
  end

  defp extract_elixir_character(%LSPosition{} = position, line(text: utf8_text)) do
    case CodeUnit.utf16_offset_to_utf8_offset(utf8_text, position.character) do
      {:ok, _code_unit} = result -> result
      {:error, :out_of_bounds} -> {:ok, position.character + 1}
      {:error, _reason} = result -> result
    end
  end
end
