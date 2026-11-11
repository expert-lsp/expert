defmodule ExpertExtensions.Test.Request do
  @moduledoc false

  @closing_delimiters %{"(" => ")", "[" => "]", "{" => "}", "<" => ">"}
  @heredoc_delimiters [~s("""), ~s(''')]

  def build(text, opts \\ []) do
    [before, after_cursor] = String.split(text, "|", parts: 2)
    source = before <> after_cursor
    lines = String.split(before, "\n")
    line_prefix = List.last(lines)
    position = %{line: length(lines), character: columns(line_prefix) + 1}
    ancestors = ancestors(before)
    call = call(ancestors, source, opts[:call])
    {identifier, range} = identifier_at(source, position)
    path = Path.join(File.cwd!(), "lib/source.ex")

    %{
      aliases: Keyword.get(opts, :aliases, %{}),
      ancestors: ancestors,
      call: call,
      context: :code,
      hint: hint(line_prefix),
      imports: Keyword.get(opts, :imports, []),
      language_id: Keyword.get(opts, :language_id, "elixir"),
      identifier: identifier,
      module: opts[:module],
      path: path,
      position: position,
      range: range,
      semantic: %{scope: opts[:scope], target: call.target},
      sigil: if(opts[:sigil], do: sigil(source, before, opts[:sigil])),
      source: source,
      uri: "file://" <> path
    }
  end

  def range({start_line, start_character}, {end_line, end_character}) do
    %{
      start: %{line: start_line, character: start_character},
      end: %{line: end_line, character: end_character}
    }
  end

  defp ancestors(before) do
    case Code.Fragment.container_cursor_to_quoted(before, parser_options()) do
      {:ok, quoted} -> quoted |> Macro.path(&match?({:__cursor__, _, _}, &1)) |> List.wrap()
      {:error, _error} -> []
    end
  end

  defp parser_options do
    [
      columns: true,
      token_metadata: true,
      unescape: false,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}}
    ]
  end

  defp call(_ancestors, _source, nil), do: %{args: [], ast: nil, target: nil}

  # A piped value counts as the first argument of the call on the right of the
  # pipe. The call of the request is then the whole pipe.
  defp call(ancestors, source, {module, name}) do
    path = Enum.reverse(ancestors)

    {call, container, arguments} =
      for {parent, {form, _, arguments} = node} <- Enum.zip([nil | path], path),
          is_list(arguments),
          call_name(form) == name do
        case parent do
          {:|>, _, [left, ^node]} -> {node, parent, [left | arguments]}
          _parent -> {node, node, arguments}
        end
      end
      |> List.last()

    piped = if container == call, do: 0, else: 1

    arity =
      case document_arity(source, call) do
        {:ok, count} -> count + piped
        :error -> length(arguments)
      end

    %{args: arguments, ast: container, target: {module, name, arity}}
  end

  # The source up to the cursor misses the arguments after the cursor, so the
  # arity comes from the whole source.
  defp document_arity(source, {form, meta, _arguments}) do
    location = {meta[:line], meta[:column]}

    with {:ok, ast} <- Code.string_to_quoted(source, parser_options()) do
      ast
      |> Macro.prewalker()
      |> Enum.find_value(:error, fn
        {node_form, node_meta, arguments} when is_list(node_meta) and is_list(arguments) ->
          if {node_meta[:line], node_meta[:column]} == location and
               call_name(node_form) == call_name(form),
             do: {:ok, length(arguments)}

        _node ->
          nil
      end)
    else
      _error -> :error
    end
  end

  defp call_name({:., _, [_module, name]}), do: name
  defp call_name(name), do: name

  defp hint(line_prefix) do
    case Code.Fragment.cursor_context(line_prefix) do
      {context, chars} when context in [:alias, :local_or_var, :local_call, :unquoted_atom] ->
        to_string(chars)

      {context, _base, chars} when context in [:alias, :dot] ->
        to_string(chars)

      _context ->
        ""
    end
  end

  # A cursor right after an identifier, as in `Foo|)`, reads the identifier
  # before it. `Code.Fragment` counts graphemes, but the request counts
  # codepoints.
  defp identifier_at(source, %{line: line, character: cursor}) do
    lines = String.split(source, "\n")

    character =
      lines
      |> Enum.at(line - 1, "")
      |> String.to_charlist()
      |> Enum.take(cursor - 1)
      |> List.to_string()
      |> String.length()
      |> Kernel.+(1)

    context =
      case Code.Fragment.surround_context(source, {line, character}) do
        :none when character > 1 ->
          case Code.Fragment.surround_context(source, {line, character - 1}) do
            %{end: {^line, ^character}} = context -> context
            _context -> :none
          end

        context ->
          context
      end

    with %{begin: begin, end: stop, context: context} <- context,
         identifier when is_binary(identifier) <- surround_identifier(context) do
      {identifier, range(from_graphemes(lines, begin), from_graphemes(lines, stop))}
    else
      _ -> {nil, nil}
    end
  end

  defp from_graphemes(lines, {line, column}) do
    text = lines |> Enum.at(line - 1, "") |> String.slice(0, column - 1)
    {line, columns(text) + 1}
  end

  defp surround_identifier({context, chars})
       when context in [:alias, :key, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp surround_identifier({:dot, _base, chars}), do: to_string(chars)
  defp surround_identifier(_context), do: nil

  # Returns the last `~name` sigil that opens before the cursor. `:range` covers
  # the sigil from `~` to its modifiers. `:content` covers the text between its
  # delimiters. Both ends are exclusive.
  defp sigil(source, before, name) do
    {offset, _length} = before |> :binary.matches("~" <> name) |> List.last()
    start = location(source, offset)
    opening_offset = offset + byte_size("~" <> name)
    rest = binary_part(source, opening_offset, byte_size(source) - opening_offset)

    {content_start, closing_offset, closing} =
      case Enum.find(@heredoc_delimiters, &String.starts_with?(rest, &1)) do
        nil ->
          delimiter = String.first(rest)
          closing = Map.get(@closing_delimiters, delimiter, delimiter)
          {opening_line, opening_character} = location(source, opening_offset)
          content_start = {opening_line, opening_character + 1}
          {offset, _length} = :binary.match(source, closing, scope: from(source, before))
          {content_start, offset, closing}

        delimiter ->
          {opening_line, _character} = location(source, opening_offset)
          {offset, _length} = :binary.match(source, delimiter, scope: from(source, before))
          {{opening_line + 1, 1}, offset, delimiter}
      end

    {closing_line, closing_character} = location(source, closing_offset)
    after_closing = closing_offset + byte_size(closing)

    modifiers = modifiers(binary_part(source, after_closing, byte_size(source) - after_closing))

    %{
      name: name,
      range: range(start, {closing_line, closing_character + columns(closing) + modifiers}),
      content: range(content_start, {closing_line, closing_character})
    }
  end

  defp modifiers(<<char, rest::binary>>) when char in ?a..?z or char in ?A..?Z,
    do: 1 + modifiers(rest)

  defp modifiers(_rest), do: 0

  defp from(source, before), do: {byte_size(before), byte_size(source) - byte_size(before)}

  defp location(source, offset) do
    lines = source |> binary_part(0, offset) |> String.split("\n")
    {length(lines), columns(List.last(lines)) + 1}
  end

  # Positions count codepoints, like the columns of the Elixir parser.
  defp columns(text), do: text |> String.to_charlist() |> length()
end
