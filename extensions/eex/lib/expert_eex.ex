defmodule ExpertEEx do
  @moduledoc "Provides completion for EEx templates."

  @code_tokens [:expr, :start_expr, :middle_expr, :end_expr]

  def complete(%{source: source, position: position}) do
    with {:ok, tokens} <- tokenize(source),
         {masked, spans} = mask(source, tokens),
         true <- Enum.any?(spans, &within?(position, &1)) do
      %{delegate: %{source: masked}}
    else
      _ -> %{mode: :override, items: [], incomplete?: false}
    end
  end

  # While the user types, the tag at the cursor is often unclosed, as in
  # `<%= foo`. EEx rejects that, so this reads the template as if the tag were
  # closed.
  defp tokenize(source) do
    with {:error, _reason, _location} <- EEx.tokenize(source),
         {:error, _reason, _location} <- EEx.tokenize(source <> "%>") do
      :error
    end
  end

  # Returns the masked source, and the `{start, stop}` positions of the code in
  # each tag. Each closing `%>` becomes `;`, so tags on one line, as in
  # `<%= a %><%= b %>`, stay separate expressions.
  defp mask(source, tokens) do
    lines =
      for {line, index} <- source |> String.split("\n") |> Enum.with_index(1),
          into: %{},
          do: {index, String.duplicate(" ", columns(line))}

    {spans, lines} =
      for {type, marker, code, %{line: line, column: column}} <- tokens,
          type in @code_tokens,
          reduce: {[], lines} do
        {spans, lines} ->
          start = {line, column + 2 + length(marker)}
          {lines, stop} = write(lines, start, List.to_string(code))
          {lines, _after} = write(lines, stop, ";")
          {[{start, stop} | spans], lines}
      end

    {Enum.map_join(1..map_size(lines)//1, "\n", &lines[&1]), spans}
  end

  defp write(lines, {line, column}, text) do
    for {segment, index} <- text |> String.split("\n") |> Enum.with_index(),
        reduce: {lines, {line, column}} do
      {lines, _position} ->
        line = line + index
        column = if index == 0, do: column, else: 1

        {Map.update!(lines, line, &overwrite(&1, column, segment)),
         {line, column + columns(segment)}}
    end
  end

  defp overwrite(line, column, segment) do
    {before, rest} = split_at(line, column - 1)
    {_replaced, rest} = split_at(rest, columns(segment))
    before <> segment <> rest
  end

  defp columns(text), do: text |> String.to_charlist() |> length()

  defp split_at(text, count) do
    {before, rest} = text |> String.to_charlist() |> Enum.split(count)
    {List.to_string(before), List.to_string(rest)}
  end

  defp within?(%{line: line, character: character}, {start, stop}),
    do: {line, character} >= start and {line, character} <= stop
end
