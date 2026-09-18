defmodule Expert.Provider.Handlers.CodeFolding do
  @behaviour Expert.Provider.Handler

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
        ranges_from(ast, comments)

      {:error, ast, _parse_error, comments} when is_tuple(ast) ->
        ranges_from(ast, comments)

      _ ->
        []
    end
  end

  defp ranges_from(ast, comments) do
    {_, {blocks, strings}} =
      Macro.prewalk(ast, {[], []}, fn node, {blocks, strings} ->
        {node, {collect_block_range(node, blocks), collect_string_range(node, strings)}}
      end)

    block_ranges =
      blocks
      |> Enum.map(&to_block_folding_range/1)
      |> Enum.reject(&is_nil/1)

    block_ranges ++ Enum.reject(strings, &is_nil/1) ++ comment_ranges(comments)
  end

  defp collect_block_range({:fn, meta, _clauses}, acc) when is_list(meta),
    do: collect_anonymous_function(meta, acc)

  defp collect_block_range({_form, meta, _args}, acc) when is_list(meta),
    do: collect_block(meta, acc)

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

  defp collect_anonymous_function(meta, acc) do
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
