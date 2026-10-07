defmodule Expert.Provider.Handlers.CodeFolding do
  @behaviour Expert.Provider.Handler

  import Forge.Document.Line

  alias Expert.Document.Context
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Enumerations.FoldingRangeKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def requires_engine?, do: false

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentFoldingRange{params: %Structures.FoldingRangeParams{}},
        %Context{} = context
      ) do
    %Context{document: document} = context
    {:ok, folding_ranges(document)}
  end

  defp folding_ranges(%Document{} = document) do
    case Ast.from(document) do
      {:ok, ast, comments} ->
        ranges_from(document, ast, comments)

      {:error, ast, _parse_error, comments} when is_tuple(ast) ->
        ranges_from(document, ast, comments)

      _ ->
        []
    end
  end

  defp ranges_from(document, ast, comments) do
    {_, {blocks, strings}} =
      Macro.prewalk(ast, {[], []}, fn node, {blocks, strings} ->
        {node, {collect_block_range(node, blocks), collect_string_range(node, strings)}}
      end)

    block_ranges =
      blocks
      |> Enum.map(&to_block_folding_range/1)
      |> Enum.reject(&is_nil/1)

    ast_ranges = block_ranges ++ Enum.reject(strings, &is_nil/1) ++ comment_ranges(comments)
    claimed_start_lines = MapSet.new(ast_ranges, & &1.start_line)

    indentation_ranges =
      document
      |> indentation_ranges()
      |> Enum.reject(&MapSet.member?(claimed_start_lines, &1.start_line))

    ast_ranges ++ indentation_ranges
  end

  defp indentation_ranges(%Document{lines: lines}) do
    lines
    |> Enum.map(fn line(text: text, line_number: line_number) ->
      {line_number - 1, indentation(text)}
    end)
    |> pair_indentation_cells([], [], [])
    |> Enum.map(fn {{start_line, _}, {end_line, _}} ->
      %Structures.FoldingRange{
        start_line: start_line,
        end_line: end_line - 1,
        kind: FoldingRangeKind.region()
      }
    end)
  end

  defp indentation(line) do
    trimmed = String.trim_leading(line)

    if trimmed != "" do
      String.length(line) - String.length(trimmed)
    end
  end

  defp pair_indentation_cells([], _stack, _empty_lines, pairs), do: valid_pairs(pairs)

  defp pair_indentation_cells([{_, nil} = cell | cells], stack, empty_lines, pairs) do
    pair_indentation_cells(cells, stack, [cell | empty_lines], pairs)
  end

  defp pair_indentation_cells([cell | cells], [], empty_lines, pairs) do
    pair_indentation_cells(cells, [cell], empty_lines, pairs)
  end

  defp pair_indentation_cells(
         [{_, indentation} = cell | cells],
         [{_, previous_indentation} | _] = stack,
         _empty_lines,
         pairs
       )
       when indentation > previous_indentation do
    pair_indentation_cells(cells, [cell | stack], [], pairs)
  end

  defp pair_indentation_cells(
         [{_, indentation} = cell | cells],
         stack,
         empty_lines,
         pairs
       ) do
    {completed, remaining} =
      Enum.split_while(stack, fn {_, previous_indentation} ->
        indentation <= previous_indentation
      end)

    completed_pairs = Enum.map(completed, &{&1, cell, empty_lines})
    pair_indentation_cells(cells, [cell | remaining], [], completed_pairs ++ pairs)
  end

  defp valid_pairs(pairs) do
    pairs
    |> Enum.map(fn
      {start_cell, end_cell, []} -> {start_cell, end_cell}
      {start_cell, _end_cell, empty_lines} -> {start_cell, List.last(empty_lines)}
    end)
    |> Enum.reject(fn {{start_line, _}, {end_line, _}} -> start_line + 1 >= end_line end)
  end

  defp collect_block_range({_form, meta, _args}, acc) when is_list(meta) do
    acc = collect_block(meta, acc)
    collect_delimited_block(meta, acc)
  end

  defp collect_block_range(_node, acc), do: acc

  defp collect_block(meta, acc) do
    do_line = meta_line(meta, :do)
    end_line = meta_line(meta, :end)

    if is_integer(do_line) and is_integer(end_line) do
      [{do_line, end_line} | acc]
    else
      acc
    end
  end

  defp collect_delimited_block(meta, acc) do
    opening_line = Keyword.get(meta, :line)
    closing_line = meta_line(meta, :closing)

    if is_integer(opening_line) and is_integer(closing_line) do
      [{opening_line, closing_line} | acc]
    else
      acc
    end
  end

  defp meta_line(meta, key) do
    case Keyword.get(meta, key) do
      keyword when is_list(keyword) -> Keyword.get(keyword, :line)
      _ -> nil
    end
  end

  defp to_block_folding_range({opening_line, closing_line}) do
    start_line = opening_line - 1
    last_line = closing_line - 2

    if last_line > start_line do
      %Structures.FoldingRange{start_line: start_line, end_line: last_line}
    end
  end

  defp collect_string_range({:__block__, meta, [str]}, acc)
       when is_binary(str) and is_list(meta),
       do: collect_string(meta, str, acc)

  defp collect_string_range({sigil, meta, [{:<<>>, _, [str]}, _mods]}, acc)
       when is_atom(sigil) and is_binary(str) and is_list(meta) do
    if match?("sigil_" <> _, Atom.to_string(sigil)) do
      collect_string(meta, str, acc)
    else
      acc
    end
  end

  defp collect_string_range(_node, acc), do: acc

  defp collect_string(meta, str, acc) do
    start_line = Keyword.get(meta, :line)
    delimiter = Keyword.get(meta, :delimiter)
    newlines = count_newlines(str)

    cond do
      not is_integer(start_line) or newlines < 1 ->
        acc

      delimiter == "\"\"\"" ->
        prepend_string_range(start_line, start_line + newlines + 1, acc)

      delimiter == "\"" ->
        prepend_string_range(start_line, start_line + newlines, acc)

      true ->
        acc
    end
  end

  defp prepend_string_range(open_line, close_line, acc) do
    start_line = open_line - 1
    end_line = close_line - 2

    if end_line > start_line do
      [%Structures.FoldingRange{start_line: start_line, end_line: end_line} | acc]
    else
      acc
    end
  end

  defp count_newlines(str) do
    str |> :binary.matches("\n") |> length()
  end

  defp comment_ranges(comments) do
    comments
    |> Enum.filter(&standalone_comment?/1)
    |> Enum.chunk_while(
      [],
      &chunk_consecutive/2,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.filter(fn chunk -> match?([_, _ | _], chunk) end)
    |> Enum.map(&to_comment_folding_range/1)
  end

  # A trailing comment (`code # comment`) has no end-of-line before it, so it
  # is not the start of a foldable comment block.
  defp standalone_comment?(%{previous_eol_count: count}), do: count > 0
  defp standalone_comment?(_), do: false

  defp chunk_consecutive(comment, [%{line: previous_line} | _] = acc)
       when comment.line == previous_line + 1 do
    {:cont, [comment | acc]}
  end

  defp chunk_consecutive(comment, acc) do
    {:cont, Enum.reverse(acc), [comment]}
  end

  defp to_comment_folding_range([first | _] = comments) do
    last = List.last(comments)

    %Structures.FoldingRange{
      start_line: first.line - 1,
      end_line: last.line - 1,
      kind: FoldingRangeKind.comment()
    }
  end
end
