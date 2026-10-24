# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.AST do
  alias Sourceror.Zipper

  @confusing_meta_tags ~w(
    line
    column
    token
  )a

  def starts_at?(macro, line), do: get_start_line(macro) == line

  def get_start_line(macro) do
    macro
    |> Zipper.zip()
    |> Zipper.traverse(:infinity, fn
      %{node: {_, meta, _}} = zipper, min_line ->
        if is_nil(meta[:line]),
          do: {zipper, min_line},
          else: {zipper, min(min_line, meta[:line])}

      zipper, min_line ->
        {zipper, min_line}
    end)
    |> elem(1)
  end

  def get_end_line(macro) do
    macro
    |> Zipper.zip()
    |> Zipper.traverse(0, fn
      %{node: {_, meta, _}} = zipper, max_line ->
        if is_nil(meta[:line]),
          do: {zipper, max_line},
          else: {zipper, max(max_line, meta[:line])}

      zipper, max_line ->
        {zipper, max_line}
    end)
    |> elem(1)
  end

  def equal?(macro, macro), do: true

  def equal?({id, _, _} = macro1, {id, _, _} = macro2),
    do: simpler_meta(macro1) == simpler_meta(macro2)

  def equal?(_, _), do: false

  def simpler_meta(node) do
    node
    |> Zipper.zip()
    |> Zipper.traverse(fn
      %{node: {id, meta, block}} = zipper ->
        Zipper.replace(
          zipper,
          {id, Keyword.filter(meta, fn {tag, _} -> tag in @confusing_meta_tags end), block}
        )

      zipper ->
        zipper
    end)
    |> Zipper.node()
  end

  def find(%Zipper{} = zipper, finder) do
    zipper
    |> Zipper.top()
    |> Zipper.traverse([], fn %{node: node} = zipper, nodes ->
      if finder.(zipper),
        do: {zipper, [node | nodes]},
        else: {zipper, nodes}
    end)
    |> elem(1)
  end

  def find(not_zipper, finder), do: find(Zipper.zip(not_zipper), finder)

  def go_to_node(zipper, node) do
    zipper
    |> Zipper.top()
    |> Zipper.traverse_while(nil, fn zipper, nil ->
      if equal?(zipper.node, node),
        do: {:halt, zipper, zipper},
        else: {:cont, zipper, nil}
    end)
    |> elem(1)
  end

  def up(zipper, times \\ 1)
  def up(nil, _), do: nil
  def up(zipper, 0), do: zipper
  def up(zipper, times), do: zipper |> Zipper.up() |> up(times - 1)

  def up_until(zipper, matcher_fn)
  def up_until(nil, _), do: nil

  def up_until(%{node: node} = zipper, matcher_fn) do
    if matcher_fn.(node),
      do: zipper,
      else: up_until(Zipper.up(zipper), matcher_fn)
  end

  def inside?(zipper, matcher_fn), do: !!up_until(zipper, matcher_fn)

  def replace_nodes(zipper, list_of_nodes, new_value),
    do: update_nodes(zipper, list_of_nodes, fn _ -> new_value end)

  def update_nodes(zipper, nodes_to_replace, updater_fn) do
    zipper
    |> Zipper.top()
    |> Zipper.traverse(fn %{node: node} = zipper ->
      if Enum.member?(nodes_to_replace, node),
        do: Zipper.update(zipper, updater_fn),
        else: zipper
    end)
  end
end
