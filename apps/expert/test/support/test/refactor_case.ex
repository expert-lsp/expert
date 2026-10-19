# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Test.RefactorCase do
  use ExUnit.CaseTemplate

  @marker_regex ~r/\s*#\s*[v\^]/

  using(opts) do
    quote do
      use ExUnit.Case, unquote(opts)

      import Expert.Test.RefactorCase
    end
  end

  defmacro assert_refactored(module, raw? \\ false, original, expected) do
    quote do
      module = unquote(module)
      original = unquote(original) |> String.trim()
      expected = unquote(expected) |> String.trim() |> String.replace("\r", "")

      range = range_from_markers(original)
      original = remove_markers(original)
      zipper = text_to_zipper(original)

      assert {:ok, selection_or_line} = selection_or_line(original, range)
      assert module.available?(zipper, selection_or_line)

      refactored = Sourceror.to_string(module.execute(zipper, selection_or_line))

      if unquote(raw?) do
        assert Sourceror.parse_string!(expected) == Sourceror.parse_string!(refactored)
      else
        assert String.split(expected, "\n") == String.split(refactored, "\n")
      end
    end
  end

  defmacro assert_ignored(module, original) do
    quote do
      module = unquote(module)
      original = unquote(original)

      range = range_from_markers(original)
      original = remove_markers(original)
      zipper = text_to_zipper(original)

      assert {:ok, selection_or_line} = selection_or_line(original, range)
      refute module.available?(zipper, selection_or_line)
    end
  end

  def range_from_markers(text) do
    text
    |> String.replace("\r", "")
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.filter(fn {text, _} -> String.match?(text, @marker_regex) end)
    |> then(fn
      [{text, line}] ->
        %{
          start: %{line: line + 1, character: String.length(text) - 1},
          end: %{line: line + 1, character: String.length(text) - 1}
        }

      [{start_text, start_line}, {end_text, end_line}] ->
        %{
          start: %{line: start_line + 1, character: String.length(start_text) - 1},
          end: %{line: end_line - 1, character: String.length(end_text)}
        }
    end)
  end

  def selection_or_line(_text, %{start: start, end: start}), do: {:ok, start.line}

  def selection_or_line(text, range) do
    text
    |> erase_outside_range(range)
    |> Sourceror.parse_string()
  end

  def text_to_zipper(text) do
    text
    |> String.replace("\r", "")
    |> Sourceror.parse_string!()
    |> Sourceror.Zipper.zip()
  end

  def remove_markers(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, @marker_regex))
    |> Enum.join("\n")
  end

  def placeholder, do: Expert.Refactor.placeholder()

  defp erase_outside_range(text, range) do
    text
    |> String.replace("\r", "")
    |> String.split(~r/(?<!\\)\n/)
    |> Stream.with_index(1)
    |> Enum.map_join("\n", fn
      {line, i} when i > range.start.line and i < range.end.line ->
        line

      {line, i} when i == range.start.line and i == range.end.line ->
        line
        |> remove_line_start(range)
        |> remove_line_end(range)

      {line, i} when i == range.start.line ->
        remove_line_start(line, range)

      {line, i} when i == range.end.line ->
        remove_line_end(line, range)

      _ ->
        ""
    end)
  end

  defp remove_line_start(line, %{start: %{character: character}}) do
    {_, line} = String.split_at(line, character)
    String.pad_leading(line, character + String.length(line), " ")
  end

  defp remove_line_end(line, %{end: %{character: character}}) do
    {line, _} = String.split_at(line, character)
    line
  end
end
