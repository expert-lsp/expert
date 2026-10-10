defmodule ExpertHEEx.Source do
  @moduledoc false

  def lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Map.new(fn {line, index} -> {index, line} end)
  end

  def slice(lines, %{start: start, end: stop} = range) do
    Enum.map_join(start.line..stop.line, "\n", fn index ->
      line = Map.fetch!(lines, index)
      {first, last} = covered(line, index, range)
      {_before, rest} = split_at(line, first - 1)
      {text, _after} = split_at(rest, last - first)
      text
    end)
  end

  def blank(lines, %{start: start, end: stop} = range) do
    Map.new(lines, fn {index, line} ->
      if index in start.line..stop.line do
        {first, last} = covered(line, index, range)
        {before, rest} = split_at(line, first - 1)
        {text, rest} = split_at(rest, last - first)
        {index, before <> spaces(text) <> rest}
      else
        {index, line}
      end
    end)
  end

  def write_code(lines, spans) do
    Enum.reduce(spans, lines, fn {start, code}, lines ->
      {lines, stop} = write(lines, start, code)
      {lines, _after} = write(lines, stop, ";")
      lines
    end)
  end

  def write(lines, {line, column}, text) do
    for {segment, index} <- text |> String.split("\n") |> Enum.with_index(),
        reduce: {lines, {line, column}} do
      {lines, _position} ->
        line = line + index
        column = if index == 0, do: column, else: 1

        {Map.update!(lines, line, &overwrite(&1, column, segment)),
         {line, column + columns(segment)}}
    end
  end

  def spaces(text), do: String.duplicate(" ", columns(text))

  def take(text, count), do: text |> split_at(count) |> elem(0)

  def columns(text), do: text |> String.to_charlist() |> length()

  def split_at(text, count) do
    {before, rest} = text |> String.to_charlist() |> Enum.split(max(count, 0))
    {List.to_string(before), List.to_string(rest)}
  end

  defp overwrite(line, column, segment) do
    {before, rest} = split_at(line, column - 1)
    {_replaced, rest} = split_at(rest, columns(segment))
    before <> segment <> rest
  end

  defp covered(line, index, %{start: start, end: stop}) do
    first = if index == start.line, do: start.character, else: 1
    last = if index == stop.line, do: stop.character, else: columns(line) + 1
    {first, last}
  end
end
