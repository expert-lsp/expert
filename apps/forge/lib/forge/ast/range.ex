defmodule Forge.Ast.Range do
  @moduledoc """
  Utilities for extracting ranges from ast nodes
  """
  alias Forge.Ast.EndPosition
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  @spec fetch(Macro.t(), Document.t()) :: {:ok, Range.t()} | :error
  def fetch(ast, %Document{} = document) do
    case positions(ast) do
      {{start_line, start_column}, {end_line, end_column}} ->
        range =
          Range.new(
            Position.new(document, start_line, start_column),
            Position.new(document, end_line, end_column)
          )

        {:ok, range}

      nil ->
        :error
    end
  end

  @definition_forms [:def, :defp, :defmacro, :defmacrop, :defmodule, :defprotocol, :defimpl]
  @end_fields [:end, :closing, :end_of_expression]

  @doc """
  Returns the start and end of a node as `{line, column}` pairs, as
  `Sourceror.get_range/1` finds them.
  """
  # A definition with an end token ranges from its start to its subtree's end
  # moved past that token. `EndPosition` finds that end the way Sourceror
  # does, without the per-node overhead of its walk.
  @spec positions(Macro.t()) ::
          {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}} | nil
  def positions({form, meta, args} = ast)
      when form in @definition_forms and is_list(meta) and is_list(args) do
    if Enum.any?(@end_fields, &Keyword.has_key?(meta, &1)) do
      [line: start_line, column: start_column] =
        Keyword.merge([line: 1, column: 1], Keyword.take(meta, [:line, :column]))

      [line: end_line, column: end_column] =
        ast
        |> EndPosition.of(line: 1, column: 1)
        |> Keyword.update!(:column, &(&1 + end_token_length(meta)))

      {{start_line, start_column}, {end_line, end_column}}
    else
      sourceror_positions(ast)
    end
  end

  def positions(ast), do: sourceror_positions(ast)

  defp end_token_length(meta) do
    cond do
      Keyword.has_key?(meta, :end_of_expression) -> 1
      Keyword.has_key?(meta, :end) -> 3
      true -> 1
    end
  end

  defp sourceror_positions(ast) do
    case Sourceror.get_range(ast) do
      %{start: start_pos, end: end_pos} ->
        [line: start_line, column: start_column] = start_pos
        [line: end_line, column: end_column] = end_pos
        {{start_line, start_column}, {end_line, end_column}}

      _ ->
        nil
    end
  end

  @spec fetch!(Macro.t(), Document.t()) :: Range.t()
  def fetch!(ast, %Document{} = document) do
    case fetch(ast, document) do
      {:ok, range} ->
        range

      :error ->
        raise ArgumentError,
          message: "Could not get a range for #{inspect(ast)} in #{document.path}"
    end
  end

  @spec get(Macro.t(), Document.t()) :: Range.t() | nil
  def get(ast, %Document{} = document) do
    case fetch(ast, document) do
      {:ok, range} -> range
      :error -> nil
    end
  end
end
