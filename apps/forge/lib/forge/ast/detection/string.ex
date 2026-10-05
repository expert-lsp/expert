defmodule Forge.Ast.Detection.String do
  use Forge.Ast.Detection

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document.Position
  alias Forge.Document.Range

  @string_sigils [
    :sigil_s,
    :sigil_S
  ]

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    case Ast.path_at(analysis, position) do
      {:ok, path} ->
        detect_string(path, position)

      _ ->
        false
    end
  end

  defp detect_string(paths, %Position{} = position) do
    {_, detected?} =
      Macro.postwalk(paths, false, fn
        ast, false ->
          detected? = do_detect(ast, position)
          {ast, detected?}

        ast, true ->
          {ast, true}
      end)

    detected?
  end

  # a string literal
  defp do_detect({:__block__, _, [literal]} = ast, %Position{} = position)
       when is_binary(literal) do
    case fetch_range(ast, 0, 0) do
      {:ok, range} -> Range.contains?(range, position)
      :error -> false
    end
  end

  # a possible string with interpolation
  defp do_detect({:<<>>, meta, _} = ast, %Position{} = position) do
    # this might also be a binary match / construction
    Keyword.has_key?(meta, :delimiter) and detect_interpolation(ast, position)
  end

  # String sigils
  defp do_detect({sigil, _, _} = ast, %Position{} = position)
       when sigil in @string_sigils do
    case fetch_range(ast, 0, 0) do
      {:ok, range} -> Range.contains?(range, position)
      _ -> false
    end
  end

  defp do_detect(_, _),
    do: false

  # a string with interpolation
  defp detect_interpolation(
         {:<<>>, meta, interpolations} = ast,
         %Position{} = position
       ) do
    delimiter_length =
      meta
      |> Keyword.get(:delimiter, "\"")
      |> String.length()

    with {:ok, string_range} <- fetch_range(ast, delimiter_length, 0),
         {:ok, interpolation_ranges} <- collect_interpolation_ranges(interpolations) do
      Range.contains?(string_range, position) and
        not Enum.any?(interpolation_ranges, &Range.contains?(&1, position))
    else
      _ ->
        false
    end
  end

  defp collect_interpolation_ranges(interpolations) do
    {_, result} =
      Macro.prewalk(interpolations, {:ok, []}, fn
        ast, :error ->
          {ast, :error}

        {:"::", _, _} = interpolation, {:ok, acc} ->
          case fetch_range(interpolation, 1, 0) do
            {:ok, range} ->
              {interpolation, {:ok, [range | acc]}}

            :error ->
              {interpolation, :error}
          end

        ast, acc ->
          {ast, acc}
      end)

    result
  end
end
