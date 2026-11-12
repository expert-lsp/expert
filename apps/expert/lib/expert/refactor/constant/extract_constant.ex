# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Constant.ExtractConstant do
  use Expert.Refactor,
    title: "Extract constant",
    kind: "refactor.extract",
    works_on: :selection

  alias Expert.Refactor.Module
  alias Expert.Refactor.NameCache
  alias Expert.Refactor.Variable

  @constant_name "extracted_constant"

  def can_refactor?(%{node: {id, _, _}}, _)
      when id in ~w(@ & alias __aliases__)a,
      do: false

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      not Module.inside_one?(zipper) ->
        false

      Enum.any?(AST.find(selection, &Variable.at_one?/1)) ->
        :skip

      match?(%{node: {:|>, _, [_, ^node]}}, Zipper.up(zipper)) ->
        false

      true ->
        true
    end
  end

  def refactor(%{node: node} = zipper, _) do
    name = next_available_constant_name(zipper)
    constant = {:@, [end_of_expression: [newlines: 2]], [{name, [], [node]}]}

    zipper
    |> Zipper.update(fn _ -> {:@, [], [{name, [], nil}]} end)
    |> Module.place_node(constant, &after_used_constants(&1, node))
  end

  def next_available_constant_name(zipper) do
    NameCache.consume_name_or(fn ->
      Module.next_available_name(
        zipper,
        @constant_name,
        &match?({:@, _, _}, &1),
        fn {_, _, [{name, _, _}]} -> name end
      )
    end)
  end

  defp after_used_constants(nodes, node) do
    constants_used = find_constants_used(node)

    nodes
    |> Stream.with_index()
    |> Stream.map(fn
      {{id, _, _}, i} when id in ~w(use alias import require)a ->
        i + 1

      {{:@, _, [{:behaviour, _, _}]}, i} ->
        i + 1

      {{:@, _, [{name, _, _}]}, i} ->
        if Enum.any?(constants_used, &match?({^name, _, _}, &1)),
          do: i + 1,
          else: 0

      _ ->
        0
    end)
    |> Enum.max()
  end

  defp find_constants_used(to_be_constant) do
    to_be_constant
    |> AST.find(&match?({:@, _, [{_, _, nil}]}, &1.node))
    |> Enum.map(fn {:@, _, [constant]} -> constant end)
  end
end
