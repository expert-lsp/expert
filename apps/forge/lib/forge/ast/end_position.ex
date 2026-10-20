defmodule Forge.Ast.EndPosition do
  @moduledoc false

  # Where a node ends, exactly as `Sourceror.get_end_position/2` computes it,
  # without its per-node overhead.
  #
  # Each node's end is the latest of its `end`, `closing` and
  # `end_of_expression` positions and its own start, an end followed by
  # newlines counting one column less. A subtree ends at the latest end of its
  # nodes, walked in post order. Positions compare by line, then column, with
  # nil as 0, and equal positions go to the one found later.
  #
  # A node with an `end` or `closing` position ends at that token at the
  # latest, and everything under it comes before it, so its children aren't
  # walked: none of them could end later, and the node, found after them,
  # would win a tie. Nodes without a position count at `default`, which
  # callers keep before any real position.

  @end_fields [:end, :closing, :end_of_expression]

  @spec of(Macro.t(), keyword()) :: keyword()
  def of(quoted, default) do
    {_key, position} = walk(quoted, {key(default), default}, default)
    position
  end

  defp walk({form, meta, args} = _node, acc, default) when is_list(meta) do
    if closed?(meta) do
      later(acc, node_end(meta, default))
    else
      acc = if is_atom(form), do: acc, else: walk(form, acc, default)
      acc = if is_list(args), do: walk_list(args, acc, default), else: acc
      later(acc, node_end(meta, default))
    end
  end

  defp walk({left, right}, acc, default), do: walk(right, walk(left, acc, default), default)
  defp walk(list, acc, default) when is_list(list), do: walk_list(list, acc, default)
  defp walk(_terminal, acc, _default), do: acc

  defp walk_list([], acc, _default), do: acc

  defp walk_list([node | rest], acc, default),
    do: walk_list(rest, walk(node, acc, default), default)

  defp closed?([]), do: false
  defp closed?([{field, _} | _]) when field in [:end, :closing], do: true
  defp closed?([_ | rest]), do: closed?(rest)

  defp node_end(meta, default) do
    candidate =
      Enum.reduce(meta, nil, fn
        {field, value}, candidate when field in @end_fields -> later(candidate, field_end(value))
        _other, candidate -> candidate
      end)

    start = [
      line: Keyword.get(meta, :line) || default[:line],
      column: Keyword.get(meta, :column) || default[:column]
    ]

    later(candidate, {key(start), start})
  end

  defp field_end([line: _, column: _] = position), do: {key(position), position}

  defp field_end(newlines: _, line: line, column: column) when is_integer(column) do
    position = [line: line, column: column - 1]
    {key(position), position}
  end

  defp field_end(field) do
    position = Keyword.take(field, [:line, :column])

    position =
      if Keyword.has_key?(field, :newlines),
        do: Keyword.update(position, :column, nil, &(&1 - 1)),
        else: position

    {key(position), position}
  end

  defp later(nil, candidate), do: candidate
  defp later({key, _} = current, {other_key, _}) when key > other_key, do: current
  defp later(_current, candidate), do: candidate

  defp key(line: line, column: column) when is_integer(line) and is_integer(column),
    do: {line, column}

  defp key(position), do: {position[:line] || 0, position[:column] || 0}
end
