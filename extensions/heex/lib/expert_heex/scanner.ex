defmodule ExpertHEEx.Scanner do
  @moduledoc false

  alias ExpertHEEx.Source

  @raw_text_tags ["script", "style"]

  def tokenize(template, opts) do
    with {:error, _reason, _location} <- EEx.tokenize(template, opts),
         {:error, _reason, _location} <- EEx.tokenize(template <> "%>", opts) do
      :error
    end
  end

  def scan(text, position, state, {events, cursor})
      when is_tuple(cursor) and position >= cursor,
      do: scan(text, position, state, {[{:cursor, state} | events], nil})

  def scan("", _position, state, events), do: {state, events}

  def scan("<!--" <> _rest = text, position, :body, events),
    do: skip(text, "<!--", position, :comment, events)

  def scan("-->" <> _rest = text, position, :comment, events),
    do: skip(text, "-->", position, :body, events)

  def scan("<" <> rest = text, position, :body, events) do
    case Regex.run(~r/^\/?[A-Za-z.:][\w.:-]*/, rest) do
      [name] ->
        event = tag_event(name, advance(position, "<"))
        skip(text, "<" <> name, position, {:tag, name}, push(events, event))

      nil ->
        skip(text, "<", position, :body, events)
    end
  end

  def scan("/>" <> _rest = text, position, {:tag, name}, events),
    do: skip(text, "/>", position, :body, push(events, {:close, name, nil}))

  def scan(">" <> _rest = text, position, {:tag, name}, events) when name in @raw_text_tags,
    do: skip(text, ">", position, {:raw, name}, events)

  def scan(">" <> _rest = text, position, {:tag, _name}, events),
    do: skip(text, ">", position, :body, events)

  def scan(<<quote, _rest::binary>> = text, position, {:tag, name}, events)
      when quote in [?", ?'],
      do: skip(text, <<quote>>, position, {:quoted, quote, name}, events)

  def scan(<<quote, _rest::binary>> = text, position, {:quoted, quote, name}, events),
    do: skip(text, <<quote>>, position, {:tag, name}, events)

  def scan("</" <> rest = text, position, {:raw, name} = state, events) do
    if String.starts_with?(rest, name <> ">") do
      event = {:close, name, advance(position, "</")}
      skip(text, "</" <> name, position, {:tag, "/" <> name}, push(events, event))
    else
      skip(text, "</", position, state, events)
    end
  end

  def scan("{" <> rest, position, :body, events),
    do: interpolation(rest, position, :body, events)

  def scan("{" <> rest, position, {:tag, _name} = state, events),
    do: interpolation(rest, position, state, events)

  def scan(text, position, {:tag, _name} = state, events) do
    case Regex.run(~r/^[\w:.@-]+/u, text) do
      [attribute] ->
        event = {:attribute, attribute, position}
        skip(text, attribute, position, state, push(events, event))

      nil ->
        next_char(text, position, state, events)
    end
  end

  def scan(text, position, state, events), do: next_char(text, position, state, events)

  def advance(position, text) do
    case String.split(text, "\n") do
      [segment] ->
        {line, column} = position
        {line, column + Source.columns(segment)}

      segments ->
        {line, _column} = position
        {line + length(segments) - 1, Source.columns(List.last(segments)) + 1}
    end
  end

  defp next_char(text, position, state, events) do
    {char, _rest} = String.next_grapheme(text)
    skip(text, char, position, state, events)
  end

  defp interpolation(rest, position, state, events) do
    start = advance(position, "{")
    {code, rest} = expression(rest)
    scan(rest, advance(start, code <> "}"), state, push(events, {:code, start, code}))
  end

  defp skip(text, skipped, position, state, events) do
    rest = binary_part(text, byte_size(skipped), byte_size(text) - byte_size(skipped))
    scan(rest, advance(position, skipped), state, events)
  end

  defp tag_event("/" <> name, {line, column}), do: {:close, name, {line, column + 1}}
  defp tag_event(name, start), do: {:open, name, start}

  defp expression(text) do
    case Code.string_to_quoted(text, columns: true) do
      {:error, {metadata, _message, token}} when token in ["}", ~c"}"] ->
        split_closing_brace(text, metadata[:line], metadata[:column])

      _result ->
        {text, ""}
    end
  end

  defp split_closing_brace(text, line, column) do
    {before_lines, [line_text | after_lines]} =
      text |> String.split("\n") |> Enum.split(line - 1)

    {before, "}" <> rest} = Source.split_at(line_text, column - 1)
    code = Enum.join(before_lines ++ [before], "\n")
    rest = Enum.join([rest | after_lines], "\n")
    {code, rest}
  end

  defp push({events, cursor}, event), do: {[event | events], cursor}
end
