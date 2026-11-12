# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.InlineAlias do
  use Expert.Refactor,
    title: "Inline alias",
    kind: "refactor.inline",
    works_on: :selection

  alias Expert.Refactor.Alias

  def can_refactor?(%{node: {:__aliases__, _, _}} = zipper, selection) do
    cond do
      not Alias.contains_selection?(zipper, selection) ->
        false

      Alias.inside_declaration?(zipper) ->
        false

      is_nil(Alias.find_declaration(zipper)) ->
        false

      true ->
        true
    end
  end

  def can_refactor?(_, _), do: false

  def refactor(%{node: {_, _, [_ | rest]}} = zipper, _),
    do: Zipper.replace(zipper, {:__aliases__, [], Alias.find_declaration(zipper) ++ rest})
end
