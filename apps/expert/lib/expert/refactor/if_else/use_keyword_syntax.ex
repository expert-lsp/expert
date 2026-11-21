# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.IfElse.UseKeywordSyntax do
  use Expert.Refactor,
    title: "Rewrite if else using keyword syntax",
    kind: "refactor.rewrite",
    works_on: :line

  alias Expert.Refactor.Block

  def can_refactor?(%{node: {:if, meta, [_, blocks]} = node}, line) do
    cond do
      not AST.starts_at?(node, line) ->
        false

      # keyword if else doesn't have :do tag
      is_nil(meta[:do]) ->
        :skip

      Enum.any?(blocks, &Block.has_multiple_statements?/1) ->
        false

      true ->
        true
    end
  end

  def can_refactor?(_, _), do: false

  def refactor(zipper, _) do
    Zipper.update(zipper, fn
      {:if, meta, [condition, blocks]} ->
        {:if, Keyword.drop(meta, [:do, :end]),
         [
           condition,
           Enum.map(blocks, &use_keyword_syntax/1)
         ]}
    end)
  end

  defp use_keyword_syntax({{:__block__, meta, tag}, inner_block}),
    do: {{:__block__, Keyword.put(meta, :format, :keyword), tag}, inner_block}
end
