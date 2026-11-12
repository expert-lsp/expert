# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.UseRegularSyntax do
  use Expert.Refactor,
    title: "Rewrite keyword function using regular syntax",
    kind: "refactor.rewrite",
    works_on: :line

  alias Expert.Refactor.Function

  def can_refactor?(%{node: node} = zipper, line) do
    with true <- Function.definition?(node),
         true <- AST.starts_at?(node, line),
         %{node: {{:__block__, block_meta, _}, _}} <- Function.go_to_block(zipper) do
      block_meta[:format] == :keyword
    else
      _ -> false
    end
  end

  def refactor(zipper, _) do
    zipper
    |> Zipper.update(fn {function, meta, macro} ->
      {function, Keyword.merge(meta, do: [], end: []), macro}
    end)
    |> Function.go_to_block()
    |> Zipper.update(fn {{:__block__, meta, [:do]}, macro} ->
      {{:__block__, Keyword.delete(meta, :format), [:do]}, macro}
    end)
  end
end
