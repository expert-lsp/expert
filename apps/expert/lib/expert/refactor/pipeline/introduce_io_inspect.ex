# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.IntroduceIOInspect do
  use Expert.Refactor,
    title: "Introduce IO.inspect",
    kind: "quickfix",
    works_on: :selection

  alias Expert.Refactor.Variable

  @io_inspect_call {{:., [], [{:__aliases__, [], [:IO]}, :inspect]}, [], []}

  def can_refactor?(_, {:&, _, [body]})
      when not is_number(body),
      do: false

  def can_refactor?(_, {id, _, _})
      when id in ~w(<- alias __aliases__)a,
      do: :skip

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      Variable.inside_declaration?(zipper) ->
        false

      invalid_parent?(zipper) ->
        false

      true ->
        true
    end
  end

  def refactor(%{node: node} = zipper, _),
    do: Zipper.replace(zipper, {:|>, [], [node, @io_inspect_call]})

  defp invalid_parent?(%{node: node} = zipper) do
    case Zipper.up(zipper) do
      %{node: {:|>, _, [_, ^node]}} -> true
      %{node: {:@, _, [^node]}} -> true
      _ -> false
    end
  end
end
