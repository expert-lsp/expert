defmodule Engine.Search.Indexer.Metadata do
  @moduledoc """
  Utilities for extracting location information from AST metadata nodes.
  """
  def location({_, metadata, _} = ast) do
    if Keyword.has_key?(metadata, :do) do
      position = position(metadata)
      block_start = position(metadata, :do)
      block_end = position(metadata, :end_of_expression) || position(metadata, :end)
      {:block, position, block_start, block_end}
    else
      maybe_handle_terse_function(ast)
    end
  end

  def location(_unknown) do
    {:expression, nil}
  end

  def position(keyword) do
    line = Keyword.get(keyword, :line)
    column = Keyword.get(keyword, :column)

    if is_number(line) and is_number(column) do
      {line, column}
    end
  end

  def position(keyword, key) do
    keyword
    |> Keyword.get(key, [])
    |> position()
  end

  @defines [:def, :defp, :defmacro, :defmacrop, :fn]
  # a terse function is one without a do/end block
  defp maybe_handle_terse_function({define, metadata, [_name_and_args | [[block | _]]]})
       when define in @defines do
    block_location(block, metadata)
  end

  defp maybe_handle_terse_function({:fn, metadata, _} = ast) do
    block_location(ast, metadata)
  end

  defp maybe_handle_terse_function({_, metadata, _}) do
    {:expression, position(metadata)}
  end

  defp block_location(block, metadata) do
    case Sourceror.get_range(block) do
      %{start: start_pos, end: end_pos} ->
        position = position(metadata)
        {:block, position, keyword_to_position(start_pos), keyword_to_position(end_pos)}

      _ ->
        {:expression, position(metadata)}
    end
  end

  defp keyword_to_position(keyword) do
    case Keyword.take(keyword, [:line, :column]) do
      [line: line, column: column] when is_number(line) and is_number(column) ->
        {line, column}

      _ ->
        nil
    end
  end
end
