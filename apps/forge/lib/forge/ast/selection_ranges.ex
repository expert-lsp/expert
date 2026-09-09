defmodule Forge.Ast.SelectionRanges do
  @moduledoc """
  This module provides nested ranges for editor selection expansion.

  ## Supported cases

  The algorithm combines five selection types:

    1. **Delimiters:** {}, {}, (), do ... end, call arguments.
    2. **Indentation:** A cursor inside the body below selects `first()` and
       `second()` together, with or without the first line's indentation:

       ```elixir
       foo do
         first()
         second()
       end
       ```

    3. **Comments:** Each line and the complete comment block are separate selections.
    4. **Text at the cursor:** `Some.Module.function()` offers the name
       `Some.Module.function` separately from the complete call.
    5. **Expressions:** Selections cover nested calls such as `outer(inner(value))`,
       grouping such as `(a + b)`, and containers such as `[a, b]`, `{a, b}`, and
       `%User{name: value}`. Access expressions such as `map[key]` offer `key`
       and `[key]` separately.

  A cursor inside `value` in `outer(inner(value))` produces this expansion sequence:

  ```text
  value -> (value) -> inner(value) -> (inner(value)) -> outer(inner(value))
  ```

  Each cursor receives a separate expansion sequence.
  Expansion ends at the whole document, even for empty or whitespace-only input.
  """

  import Forge.Document.Line
  import Sourceror.Identifier, only: [is_unqualified_call: 1]

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.CodeUnit
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Sourceror.FastZipper

  @doc """
  Returns ranges from largest to smallest for each cursor.
  It preserves cursor order and duplicate positions.
  An empty cursor list produces an empty result.
  """
  def ranges(_analysis, []), do: []

  def ranges(%Analysis{} = analysis, positions) do
    full_range = document_range(analysis.document)
    indentation_ranges = indentation_ranges(analysis.document)

    selections =
      for position <- positions do
        indentation_matches =
          Enum.filter(indentation_ranges, &Range.contains_cursor?(&1, position))

        sources = %{
          delimiters: [],
          indentation: indentation_matches,
          comments: comment_ranges(analysis, position),
          lexical: surround_ranges(analysis, position),
          ast: []
        }

        {position, sources}
      end

    {_zipper, selections} =
      analysis.ast
      |> FastZipper.zip()
      |> FastZipper.traverse_while(selections, fn zipper, selections ->
        if skip_block_body?(zipper, analysis, positions) do
          {:skip, zipper, selections}
        else
          node = FastZipper.node(zipper)
          ast_ranges = node_ranges(node, analysis)

          selections =
            for {position, sources} <- selections do
              ast_matches =
                Enum.filter(ast_ranges, &Range.contains_cursor?(&1, position))

              delimiter_matches =
                block_ranges(node, analysis.document, position) ++
                  call_ranges(node, analysis.document, position) ++
                  container_ranges(node, analysis.document, position) ++
                  clause_ranges(node, analysis.document, position)

              updated_sources = %{
                sources
                | ast: ast_matches ++ sources.ast,
                  delimiters: delimiter_matches ++ sources.delimiters
              }

              {position, updated_sources}
            end

          {:cont, zipper, selections}
        end
      end)

    for {position, sources} <- selections do
      merge_sources(sources, position, full_range)
    end
  end

  defp merge_sources(sources, position, full_range) do
    # Earlier sources take precedence when ranges cross.
    [:delimiters, :indentation, :comments, :lexical, :ast]
    |> Enum.reduce([full_range], fn source, merged ->
      ranges =
        Enum.filter(Map.fetch!(sources, source), fn range ->
          Range.contains_cursor?(range, position) and encloses?(full_range, range)
        end)

      nested =
        [full_range | ranges]
        |> Enum.uniq()
        |> Enum.sort(fn left, right ->
          case Position.compare(left.start, right.start) do
            :gt -> true
            :lt -> false
            :eq -> Position.compare(left.end, right.end) != :gt
          end
        end)
        |> Enum.reduce([], fn
          range, [] ->
            [range]

          parent, [child | _] = nested ->
            if encloses?(parent, child) do
              [parent | nested]
            else
              nested
            end
        end)

      merge_ranges(merged, nested)
    end)
  end

  # A cursor in a call's arguments needs ranges for the arguments and the call.
  # We can skip the body when every requested cursor is outside it:
  #
  #     custom(arg|ument) do
  #       inner(value)
  #     end
  #
  # Here, we visit `custom` and `argument`, then skip `inner(value)`.
  # A second cursor inside `value` makes us visit the body too.
  #
  # We use this shortcut only when the code is valid and the block's `do` and
  # `end` belong to the call. For incomplete code or uncertain block boundaries,
  # we visit the body.
  defp skip_block_body?(
         zipper,
         %Analysis{valid?: true, document: document},
         positions
       ) do
    with [{{:__block__, key_meta, [:do]}, _body} | _] <- FastZipper.node(zipper),
         parent when parent != nil <- FastZipper.up(zipper),
         {_call, meta, _args} <- FastZipper.node(parent) do
      case {meta[:do], meta[:end]} do
        {[line: start_line, column: start_column] = do_meta, [line: end_line, column: end_column]} ->
          start = Position.new(document, start_line, start_column)
          finish = Position.new(document, end_line, end_column)
          body_range = Range.new(start, finish)

          same_block? = Keyword.take(key_meta, [:line, :column]) == do_meta
          ordered? = Position.compare(start, finish) == :lt

          same_block? and ordered? and
            not Enum.any?(positions, &Range.contains?(body_range, &1))

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp skip_block_body?(_zipper, _analysis, _positions), do: false

  defp node_ranges(node, %Analysis{} = analysis) do
    document = analysis.document

    parens =
      case node do
        {_form, meta, _args} when is_list(meta) ->
          parens = Keyword.get_values(meta, :parens)

          for paren <- parens,
              [line: end_line, column: end_column] <- [paren[:closing]],
              range <- [
                Range.new(
                  Position.new(document, paren[:line], paren[:column]),
                  Position.new(document, end_line, end_column + 1)
                ),
                Range.new(
                  Position.new(document, paren[:line], paren[:column] + 1),
                  Position.new(document, end_line, end_column)
                )
              ] do
            range
          end

        _ ->
          []
      end

    ranges = List.wrap(ast_range(node, analysis))

    Enum.concat([ranges, parens])
  end

  defp ast_range({:., _, _}, _analysis), do: nil

  defp ast_range({left, right}, analysis) do
    case {child_range(left, analysis), child_range(right, analysis)} do
      {%Range{} = left, %Range{} = right} -> Range.new(left.start, right.end)
      {%Range{} = range, nil} -> range
      {nil, %Range{} = range} -> range
      {nil, nil} -> nil
    end
  end

  defp ast_range([first | _] = nodes, analysis) do
    if Enum.all?(nodes, &match?({_, _}, &1)) do
      case {ast_range(first, analysis), ast_range(List.last(nodes), analysis)} do
        {%Range{} = first, %Range{} = last} -> Range.new(first.start, last.end)
        _ -> nil
      end
    end
  end

  defp ast_range({:not, meta, [{:in, _, _} = expression]} = node, analysis) do
    range = Ast.Range.get(expression, analysis.document)
    operator = Position.new(analysis.document, meta[:line], meta[:column])

    if range && Position.compare(range.start, operator) == :lt do
      range
    else
      Ast.Range.get(node, analysis.document)
    end
  end

  defp ast_range({:__block__, meta, [keyword]} = node, analysis)
       when keyword in [:do, :else, :rescue, :catch, :after] do
    text = Atom.to_string(keyword)

    if meta[:format] != :keyword and text_at(analysis.document, meta, String.length(text)) == text do
      Range.new(
        Position.new(analysis.document, meta[:line], meta[:column]),
        Position.new(analysis.document, meta[:line], meta[:column] + String.length(text))
      )
    else
      Ast.Range.get(node, analysis.document)
    end
  end

  defp ast_range({:__block__, [], [first | _] = expressions} = node, analysis) do
    case {first, List.last(expressions)} do
      {{:__block__, first_meta, []}, {:__block__, last_meta, []}} ->
        if first_meta[:error] && last_meta[:error] &&
             text_at(analysis.document, first_meta, 2) == "do" &&
             text_at(analysis.document, last_meta, 3) == "end" do
          Range.new(
            Position.new(analysis.document, first_meta[:line], first_meta[:column]),
            Position.new(analysis.document, last_meta[:line], last_meta[:column] + 3)
          )
        else
          Ast.Range.get(node, analysis.document)
        end

      _ ->
        Ast.Range.get(node, analysis.document)
    end
  end

  defp ast_range({form, meta, args}, analysis) do
    Ast.Range.get({form, Keyword.delete(meta, :parens), args}, analysis.document)
  end

  defp ast_range(node, analysis), do: Ast.Range.get(node, analysis.document)

  defp child_range({_, _, _} = node, analysis), do: ast_range(node, analysis)
  defp child_range(_node, _analysis), do: nil

  defp text_at(document, meta, length) do
    case Document.fetch_text_at(document, meta[:line]) do
      {:ok, text} -> String.slice(text, meta[:column] - 1, length)
      :error -> ""
    end
  end

  defp comment_ranges(%Analysis{} = analysis, %Position{} = position) do
    document = analysis.document

    case Map.get(analysis.comments_by_line, position.line) do
      nil ->
        []

      comment ->
        range =
          Range.new(
            Position.new(document, comment.line, comment.column),
            Position.new(document, comment.line, comment.column + String.length(comment.text))
          )

        cond do
          not Range.contains?(range, position) ->
            []

          comment.previous_eol_count == 0 ->
            []

          true ->
            first = comment_block_boundary(analysis.comments_by_line, comment, -1)
            last = comment_block_boundary(analysis.comments_by_line, comment, 1)

            block_end =
              Position.new(document, last.line, last.column + String.length(last.text))

            [
              range,
              Range.new(Position.new(document, comment.line, 1), range.end),
              Range.new(Position.new(document, first.line, first.column), block_end),
              Range.new(Position.new(document, first.line, 1), block_end)
            ]
        end
    end
  end

  defp comment_block_boundary(comments, comment, step) do
    case Map.get(comments, comment.line + step) do
      %{previous_eol_count: count} = adjacent when count > 0 ->
        comment_block_boundary(comments, adjacent, step)

      _ ->
        comment
    end
  end

  defp document_range(document) do
    last_line_number = Document.size(document)

    finish =
      case Document.fetch_line_at(document, last_line_number) do
        {:ok, line(text: text, ending: "")} ->
          Position.new(document, last_line_number, String.length(text) + 1)

        {:ok, line(ending: ending)} when ending in ["\n", "\r", "\r\n"] ->
          Position.new(document, last_line_number + 1, 1)

        :error ->
          Position.new(document, 1, 1)
      end

    Range.new(Position.new(document, 1, 1), finish)
  end

  defp indentation_ranges(document) do
    {_open_lines, _previous_line, ranges} =
      Enum.reduce(document.lines, {[], nil, []}, fn
        line(text: ""), state ->
          state

        line(line_number: number, text: text), {open_lines, previous_line, ranges} ->
          indent =
            CodeUnit.count(:utf16, text) - CodeUnit.count(:utf16, String.trim_leading(text))

          {closed, open_lines} =
            Enum.split_while(open_lines, fn {_line, open_indent} -> open_indent >= indent end)

          closed_ranges =
            Enum.flat_map(closed, fn opening ->
              indentation_ranges(document, opening, previous_line)
            end)

          {
            [{number, indent} | open_lines],
            {number, String.length(text) + 1},
            closed_ranges ++ ranges
          }
      end)

    ranges
  end

  defp indentation_ranges(document, {start_line, indent}, {end_line, end_column})
       when end_line > start_line do
    {:ok, first_body_text} = Document.fetch_text_at(document, start_line + 1)

    body_indent =
      String.length(first_body_text) - String.length(String.trim_leading(first_body_text))

    finish = Position.new(document, end_line, end_column)

    [
      Range.new(Position.new(document, start_line, indent + 1), finish),
      Range.new(Position.new(document, start_line + 1, 1), finish),
      Range.new(Position.new(document, start_line + 1, body_indent + 1), finish)
    ]
  end

  defp indentation_ranges(_document, _opening, _previous_line), do: []

  defp surround_ranges(%Analysis{} = analysis, %Position{} = position) do
    case Ast.surround_context(analysis, position) do
      {:ok, %{begin: {start_line, start_column}, end: {end_line, end_column}, context: context}} ->
        lexical_only? = elem(context, 0) in [:key, :keyword, :operator, :sigil]

        if lexical_only? and {position.line, position.character} == {end_line, end_column} do
          []
        else
          [
            Range.new(
              Position.new(analysis.document, start_line, start_column),
              Position.new(analysis.document, end_line, end_column)
            )
          ]
        end

      {:error, :surround_context} ->
        []
    end
  end

  defp block_ranges(node, document, position) do
    node
    |> block_boundaries(document)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{name, start}, {next_name, finish}] ->
      outer_finish =
        if next_name == :end do
          Position.new(document, finish.line, finish.character + 3)
        else
          finish
        end

      outer = Range.new(start, outer_finish)

      if Position.compare(start, finish) == :lt and Range.contains?(outer, position) do
        inner =
          cond do
            next_name != :end ->
              after_keyword =
                Position.new(
                  document,
                  start.line,
                  start.character + String.length(Atom.to_string(name))
                )

              Range.new(after_keyword, finish)

            position.line > start.line and position.line < finish.line ->
              {:ok, last_body_text} = Document.fetch_text_at(document, finish.line - 1)

              Range.new(
                Position.new(document, start.line + 1, 1),
                Position.new(document, finish.line - 1, String.length(last_body_text) + 1)
              )

            true ->
              nil
          end

        inner_ranges =
          Enum.filter(List.wrap(inner), fn range ->
            Position.compare(range.start, range.end) == :lt
          end)

        Enum.filter([outer | inner_ranges], &Range.contains_cursor?(&1, position))
      else
        []
      end
    end)
  end

  defp block_boundaries({_form, meta, args}, document) when is_list(args) do
    case {meta[:end], List.last(args)} do
      {[line: end_line, column: end_column],
       [{{:__block__, do_meta, [:do]}, _body} | _] = sections} ->
        if Keyword.take(do_meta, [:line, :column]) == meta[:do] do
          boundaries =
            for {{:__block__, section_meta, [name]}, _body} <- sections do
              {name, Position.new(document, section_meta[:line], section_meta[:column])}
            end

          boundaries ++ [{:end, Position.new(document, end_line, end_column)}]
        else
          []
        end

      _ ->
        []
    end
  end

  defp block_boundaries(_node, _document), do: []

  defp call_ranges({{:., _, [_, name]}, meta, args}, document, position)
       when is_atom(name) and is_list(args) do
    call_ranges({name, meta, args}, document, position)
  end

  defp call_ranges({{:., _, [_callee]}, meta, _args}, document, position) do
    delimited_ranges(document, meta, meta[:column] + 1, {"(", ")"}, position)
  end

  defp call_ranges({name, meta, _args} = node, document, position)
       when is_unqualified_call(node) do
    case meta[:closing] do
      [line: _, column: _] ->
        unqualified_call_ranges(name, meta, document, position)

      _ ->
        []
    end
  end

  defp call_ranges(_node, _document, _position), do: []

  defp unqualified_call_ranges(name, meta, document, position) do
    name_length =
      if meta[:delimiter] in ["\"", "'"] do
        {:ok, text} = Document.fetch_text_at(document, meta[:line])
        name_source = String.slice(text, (meta[:column] - 1)..-1//1)

        case Regex.run(~r/^(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/u, name_source) do
          [quoted_name] -> String.length(quoted_name)
          nil -> nil
        end
      else
        String.length(Atom.to_string(name))
      end

    if name_length do
      delimited_ranges(document, meta, meta[:column] + name_length, {"(", ")"}, position)
    else
      []
    end
  end

  defp container_ranges({_form, meta, _args} = node, document, position) do
    case container_delimiters(node) do
      {opening, _closing} = delimiters ->
        column =
          if opening == "{" and text_at(document, meta, 1) == "%" do
            meta[:column] + 1
          else
            meta[:column]
          end

        delimited_ranges(document, meta, column, delimiters, position)

      _ ->
        []
    end
  end

  defp container_ranges(_node, _document, _position), do: []

  defp container_delimiters({{:., _, [Access, :get]}, meta, _args}) do
    if meta[:from_brackets], do: {"[", "]"}
  end

  defp container_delimiters({:__block__, meta, [literal]}) when is_list(literal) do
    if is_nil(meta[:delimiter]), do: {"[", "]"}
  end

  defp container_delimiters({:__block__, _, [literal]}) when is_tuple(literal), do: {"{", "}"}
  defp container_delimiters({form, _, _}) when form in [:%{}, :{}], do: {"{", "}"}

  defp container_delimiters({:<<>>, meta, _}) do
    if is_nil(meta[:delimiter]), do: {"<<", ">>"}
  end

  defp container_delimiters(_node), do: nil

  defp delimited_ranges(document, meta, column, {opening, closing}, position) do
    case meta[:closing] do
      [line: end_line, column: end_column] ->
        start = Position.new(document, meta[:line], column)
        inside_start = Position.new(document, meta[:line], column + String.length(opening))
        finish = Position.new(document, end_line, end_column)
        outside_end = Position.new(document, end_line, end_column + String.length(closing))
        outer = Range.new(start, outside_end)
        inner = Range.new(inside_start, finish)

        if Document.fragment(document, start, inside_start) == opening and
             Document.fragment(document, finish, outside_end) == closing and
             Range.contains?(outer, position) do
          Enum.filter([outer, inner], &Range.contains_cursor?(&1, position))
        else
          []
        end

      _ ->
        []
    end
  end

  defp clause_ranges({:->, meta, _} = node, document, position) do
    case Ast.Range.fetch(node, document) do
      {:ok, range} ->
        pattern = Range.new(range.start, Position.new(document, meta[:line], meta[:column] + 2))
        if Range.contains_cursor?(pattern, position), do: [pattern], else: []

      :error ->
        []
    end
  end

  defp clause_ranges(_node, _document, _position), do: []

  # Merge algorithm
  #
  # This function combines two lists of selections. Each list starts with the
  # whole document, and each later range fits inside the previous range.
  #
  # The function compares the first remaining range from each list:
  # * If the ranges are equal, it keeps one copy.
  # * If one range contains the other, it keeps the larger range first.
  # * If each range extends beyond the other, it adds their combined span, then
  #   the range from the first list. It trims subsequent ranges from the second
  #   list to fit inside the last range in the result.
  #
  # For example, with the cursor at |:
  #
  #     if ready? do
  #       |:ok
  #     else
  #       :error
  #     end
  #
  # Two sources select different text around the cursor:
  #
  #     Indentation: "if ready? do\n  :ok"
  #     Delimiters:  "do\n  :ok\n"
  #
  # The indentation range starts earlier. The delimiter range ends later.
  # The algorithm gives delimiter ranges priority over indentation ranges.
  # The function adds "if ready? do\n  :ok\n" to contain both ranges.
  # The editor can then expand from "do\n  :ok\n" to "if ready? do\n  :ok\n".
  #
  # Source: ElixirLS RangeUtils.merge_ranges_lists/2
  # https://github.com/elixir-lsp/elixir-ls/blob/68df44b681ee0dbef91b8008b0354003a9a451fa/apps/language_server/lib/language_server/range_utils.ex#L123
  defp merge_ranges([root | left], [root | right]) do
    merge_ranges(left, right, [root])
  end

  defp merge_ranges([], [], collected) do
    Enum.reverse(collected)
  end

  defp merge_ranges([left | rest], [], collected) do
    merge_ranges(rest, [], [left | collected])
  end

  defp merge_ranges([], [right | rest], [parent | _] = collected) do
    # Each later selection stays inside the last selected parent.
    right = intersection(right, parent)
    merge_ranges([], rest, [right | collected])
  end

  defp merge_ranges([range | left], [range | right], collected) do
    merge_ranges(left, right, [range | collected])
  end

  defp merge_ranges(
         [left | left_rest],
         [right | right_rest],
         [parent | _] = collected
       ) do
    right = intersection(right, parent)

    cond do
      encloses?(left, right) ->
        merge_ranges(left_rest, [right | right_rest], [left | collected])

      encloses?(right, left) ->
        merge_ranges([left | left_rest], right_rest, [right | collected])

      true ->
        merge_ranges(
          left_rest,
          right_rest,
          [left, union(left, right) | collected]
        )
    end
  end

  defp encloses?(parent, child) do
    Position.compare(parent.start, child.start) != :gt and
      Position.compare(child.end, parent.end) != :gt
  end

  defp union(left, right) do
    Range.new(
      Enum.min([left.start, right.start], Position),
      Enum.max([left.end, right.end], Position)
    )
  end

  # Both ranges contain the same cursor, so their intersection contains it too.
  defp intersection(left, right) do
    Range.new(
      Enum.max([left.start, right.start], Position),
      Enum.min([left.end, right.end], Position)
    )
  end
end
