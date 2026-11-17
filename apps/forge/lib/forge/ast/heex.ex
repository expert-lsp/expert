defmodule Forge.Ast.Heex do
  @moduledoc """
  Scans HEEx templates for embedded Elixir code.

  `scan/1` returns positions relative to the template. A template taken from a
  `~H` sigil with `template/1` maps them into its document with `to_document/2`.
  Positions are `{line, column}` tuples, with columns counted in codepoints, the
  same as in Elixir's AST.
  """

  defstruct [:content, :line, :column, :delimiter, :indentation]

  @type position :: {pos_integer(), pos_integer()}
  @type t :: %__MODULE__{
          content: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          delimiter: String.t(),
          indentation: non_neg_integer() | nil
        }

  @type code_type :: :expr | :start_expr | :middle_expr | :end_expr | :interpolation
  @type event :: {code_type(), String.t(), position()}

  @code_tokens [:expr, :start_expr, :middle_expr, :end_expr]
  @raw_text_tags ["script", "style"]

  @spec template(Macro.t()) :: {:ok, t()} | :error
  def template({:sigil_H, meta, [{:<<>>, content_meta, [content]}, _modifiers]})
      when is_binary(content) do
    {:ok,
     %__MODULE__{
       content: content,
       line: Keyword.fetch!(meta, :line),
       column: Keyword.fetch!(meta, :column),
       delimiter: Keyword.fetch!(meta, :delimiter),
       indentation: Keyword.get(content_meta, :indentation)
     }}
  end

  def template(_ast), do: :error

  @doc """
  Maps a position in the template to its position in the document.
  """
  @spec to_document(t(), position()) :: position()
  def to_document(%__MODULE__{indentation: indentation} = template, {line, column})
      when is_integer(indentation) do
    {template.line + line, indentation + column}
  end

  def to_document(%__MODULE__{} = template, {1, column}) do
    {template.line, template.column + 1 + String.length(template.delimiter) + column}
  end

  def to_document(%__MODULE__{} = template, {line, column}) do
    {template.line + line - 1, column}
  end

  @doc """
  Returns the code as it's written in the document, with the indentation that a
  heredoc strips from its lines.
  """
  @spec document_code(t(), String.t()) :: String.t()
  def document_code(%__MODULE__{indentation: indentation}, code)
      when is_integer(indentation) and indentation > 0 do
    String.replace(code, "\n", "\n" <> String.duplicate(" ", indentation))
  end

  def document_code(%__MODULE__{}, code), do: code

  @doc """
  Returns the Elixir code in a template, in the order it appears.

  Code comes from `<% %>` tags, typed by their EEx token, and from `{}`
  interpolations, typed `:interpolation`. Its position is that of its first
  character. Braces in comments, attribute values and `<script>` or `<style>`
  bodies aren't interpolations.
  """
  @spec scan(String.t()) :: {:ok, [event()]} | :error
  def scan(template) when is_binary(template) do
    case EEx.tokenize(template) do
      {:ok, tokens} -> {:ok, scan_tokens(tokens)}
      {:error, _message, _meta} -> :error
    end
  end

  defp scan_tokens(tokens) do
    {_state, events} =
      Enum.reduce(tokens, {:body, []}, fn
        {type, marker, code, %{line: line, column: column}}, {state, events}
        when type in @code_tokens ->
          event = {type, List.to_string(code), {line, column + 2 + length(marker)}}
          {state, [event | events]}

        {:text, text, %{line: line, column: column}}, {state, events} ->
          scan_text(List.to_string(text), {line, column}, state, events)

        _token, acc ->
          acc
      end)

    Enum.reverse(events)
  end

  defp scan_text("", _position, state, events), do: {state, events}

  defp scan_text("<!--" <> rest, position, :body, events),
    do: scan_text(rest, advance(position, 4), :comment, events)

  defp scan_text(text, position, :comment = state, events),
    do: skip_past(text, position, "-->", state, :body, events)

  defp scan_text("<" <> rest, position, :body, events) do
    case tag_name(rest) do
      "" ->
        scan_text(rest, advance(position, 1), :body, events)

      name ->
        next = advance(position, 1 + String.length(name))
        scan_text(drop(rest, name), next, {:tag, name}, events)
    end
  end

  defp scan_text(">" <> rest, position, {:tag, name}, events) when name in @raw_text_tags,
    do: scan_text(rest, advance(position, 1), {:raw, name}, events)

  defp scan_text(">" <> rest, position, {:tag, _name}, events),
    do: scan_text(rest, advance(position, 1), :body, events)

  defp scan_text(<<quote, rest::binary>>, position, {:tag, name}, events)
       when quote in [?", ?'],
       do: scan_text(rest, advance(position, 1), {:quoted, quote, name}, events)

  defp scan_text(text, position, {:quoted, quote, name} = state, events),
    do: skip_past(text, position, <<quote>>, state, {:tag, name}, events)

  defp scan_text(text, position, {:raw, name} = state, events) do
    case :binary.split(text, "</" <> name) do
      [raw, rest] -> scan_text("</" <> name <> rest, advance_over(position, raw), :body, events)
      [_raw] -> {state, events}
    end
  end

  defp scan_text("{" <> rest, position, state, events) do
    case split_interpolation(rest, 0, "") do
      {:ok, code, rest} ->
        code_position = advance(position, 1)
        next = code_position |> advance_over(code) |> advance(1)
        scan_text(rest, next, state, [{:interpolation, code, code_position} | events])

      :error ->
        scan_text(rest, advance(position, 1), state, events)
    end
  end

  defp scan_text(<<char::utf8, rest::binary>>, position, state, events),
    do: scan_text(rest, advance_over(position, <<char::utf8>>), state, events)

  defp skip_past(text, position, terminator, state, next_state, events) do
    case :binary.split(text, terminator) do
      [skipped, rest] ->
        next = position |> advance_over(skipped) |> advance(String.length(terminator))
        scan_text(rest, next, next_state, events)

      [_skipped] ->
        {state, events}
    end
  end

  defp split_interpolation("}" <> rest, 0, code), do: {:ok, code, rest}

  defp split_interpolation("}" <> rest, depth, code),
    do: split_interpolation(rest, depth - 1, code <> "}")

  defp split_interpolation("{" <> rest, depth, code),
    do: split_interpolation(rest, depth + 1, code <> "{")

  defp split_interpolation(<<quote, rest::binary>>, depth, code) when quote in [?", ?'] do
    case split_string(rest, quote, <<quote>>) do
      {:ok, string, rest} -> split_interpolation(rest, depth, code <> string)
      :error -> :error
    end
  end

  defp split_interpolation(<<char::utf8, rest::binary>>, depth, code),
    do: split_interpolation(rest, depth, code <> <<char::utf8>>)

  defp split_interpolation(_text, _depth, _code), do: :error

  defp split_string(<<?\\, char::utf8, rest::binary>>, quote, string),
    do: split_string(rest, quote, string <> <<?\\, char::utf8>>)

  defp split_string(<<quote, rest::binary>>, quote, string), do: {:ok, string <> <<quote>>, rest}

  defp split_string(<<char::utf8, rest::binary>>, quote, string),
    do: split_string(rest, quote, string <> <<char::utf8>>)

  defp split_string(_text, _quote, _string), do: :error

  defp tag_name(text) do
    case Regex.run(~r/^[A-Za-z.:][\w.:-]*/u, text) do
      [name] -> name
      nil -> ""
    end
  end

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp advance({line, column}, count), do: {line, column + count}

  @doc false
  def advance_over(position, text) do
    text
    |> String.split("\n")
    |> case do
      [single] ->
        advance(position, String.length(single))

      lines ->
        {line, _column} = position
        {line + length(lines) - 1, String.length(List.last(lines)) + 1}
    end
  end
end
