# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline do
  @moduledoc """
  └──:|>           <- top
     ├──:|>
     │  ├──:|>
     │  │  ├──:arg <- start
     │  │  └──:foo
     │  └──:bar
     └──:qez       <- end
  """

  alias Expert.Refactor.AST
  alias Sourceror.Zipper

  def starts_at?({:|>, _, [{:|>, _, _} = start, _]}, macro),
    do: starts_at?(start, macro)

  def starts_at?({:|>, _, [start, _]}, macro),
    do: AST.equal?(start, macro)

  def starts_at?(_, _), do: false

  def update_start(pipeline, updater) do
    pipeline
    |> Zipper.zip()
    |> Zipper.find(&starts_at?(pipeline, &1))
    |> Zipper.update(updater)
    |> Zipper.top()
    |> Zipper.node()
  end

  def go_to_top(zipper, {:|>, _, [_, end_]} = pipeline) do
    %{node: {:|>, _, [_, node]}} = up = Zipper.up(zipper)

    if AST.equal?(node, end_),
      do: up,
      else: go_to_top(up, pipeline)
  end
end
