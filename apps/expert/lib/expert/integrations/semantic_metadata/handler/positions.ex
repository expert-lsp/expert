defmodule Expert.Integrations.SemanticMetadata.Handler.Positions do
  @moduledoc """
  Converts positions between Expert and handlers.

  A handler position is a map with a 1-based `:line` and a 1-based `:character`
  that counts codepoints. A handler range is a map with a `:start` and an
  exclusive `:end` position.

  Expert counts columns differently: the cursor counts UTF-8 bytes, as the
  editor's position is converted, and the ranges Expert sends to the editor
  count graphemes. The three disagree on any line with non-ASCII text. In
  `e\u0301 = 1`, an `é` written with a combining accent, `=` is at byte 5,
  codepoint 4, and grapheme 3.
  """

  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  def cursor(%Document{} = document, %Position{line: line, character: character}),
    do: %{line: line, character: convert(text(document, line), character, :utf8, :codepoints)}

  def fragment_cursor(%Document{} = document, %Position{line: line, character: character}),
    do: Position.new(document, line, convert(text(document, line), character, :utf8, :graphemes))

  def range(%Document{} = document, %Range{start: start, end: stop}) do
    %{start: from_graphemes(document, start), end: from_graphemes(document, stop)}
  end

  def index_position(%Position{line: line, character: character}),
    do: %{line: line, character: character}

  def to_range(%Document{} = document, %{start: start, end: stop}) do
    with {:ok, start} <- to_position(document, start),
         {:ok, stop} <- to_position(document, stop),
         true <- Position.compare(start, stop) != :gt do
      {:ok, Range.new(start, stop)}
    else
      _ -> :error
    end
  end

  def to_range(_document, _range), do: :error

  def completion_range(_document, _cursor, nil), do: {:ok, nil}

  def completion_range(%Document{} = document, %Position{} = cursor, %{
        start: %{line: line, character: start_character},
        end: %{line: line, character: end_character}
      })
      when is_integer(line) and is_integer(start_character) and is_integer(end_character) and
             start_character <= end_character do
    %{character: character} = cursor(document, cursor)

    if line == cursor.line and start_character <= character and character <= end_character do
      text = text(document, line)

      {:ok,
       {line, convert(text, start_character, :codepoints, :graphemes),
        convert(text, end_character, :codepoints, :graphemes)}}
    else
      {:ok, nil}
    end
  end

  def completion_range(_document, _cursor, _range), do: :error

  def delegated_cursor(%Document{} = document, %Document{} = delegated, %Position{} = position) do
    %{line: line, character: character} = cursor(document, position)
    Position.new(delegated, line, convert(text(delegated, line), character, :codepoints, :utf8))
  end

  def from_delegated(
        %Range{start: start, end: stop},
        %Document{} = delegated,
        %Document{} = document
      ) do
    Range.new(
      delegated_position(start, delegated, document),
      delegated_position(stop, delegated, document)
    )
  end

  defp delegated_position(%Position{line: line} = position, delegated, document) do
    %{character: character} = from_graphemes(delegated, position)

    Position.new(
      document,
      line,
      convert(text(document, line), character, :codepoints, :graphemes)
    )
  end

  defp from_graphemes(document, %Position{line: line, character: character}),
    do: %{
      line: line,
      character: convert(text(document, line), character, :graphemes, :codepoints)
    }

  defp to_position(document, %{line: line, character: character})
       when is_integer(line) and is_integer(character) do
    with {:ok, text} <- Document.fetch_text_at(document, line),
         do:
           {:ok, Position.new(document, line, convert(text, character, :codepoints, :graphemes))}
  end

  defp to_position(_document, _position), do: :error

  defp text(document, line) do
    case Document.fetch_text_at(document, line) do
      {:ok, text} -> text
      :error -> ""
    end
  end

  defp convert(text, column, from, to),
    do: text |> prefix(column - 1, from) |> width(to) |> Kernel.+(1)

  defp prefix(text, count, :utf8),
    do: binary_part(text, 0, count |> max(0) |> min(byte_size(text)))

  defp prefix(text, count, :graphemes), do: String.slice(text, 0, max(count, 0))

  defp prefix(text, count, :codepoints),
    do: text |> String.to_charlist() |> Enum.take(max(count, 0)) |> List.to_string()

  defp width(text, :utf8), do: byte_size(text)
  defp width(text, :graphemes), do: String.length(text)
  defp width(text, :codepoints), do: text |> String.to_charlist() |> length()
end
