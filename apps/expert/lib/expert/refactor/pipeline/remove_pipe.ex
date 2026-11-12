# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.RemovePipe do
  use Expert.Refactor,
    title: "Remove pipe",
    kind: "refactor.rewrite",
    works_on: :line

  def can_refactor?(%{node: {:|>, meta, _}}, line),
    do: meta[:line] == line

  def can_refactor?(_, _), do: false

  def refactor(zipper, _) do
    zipper
    |> Zipper.update(fn {:|>, _, [arg, {id, meta, rest}]} ->
      {id, meta, [arg | rest || []]}
    end)
  end
end
