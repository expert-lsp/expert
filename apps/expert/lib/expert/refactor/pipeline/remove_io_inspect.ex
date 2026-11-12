# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.RemoveIOInspect do
  use Expert.Refactor,
    title: "Remove IO.inspect",
    kind: "quickfix",
    works_on: :line

  def can_refactor?(%{node: {:., _, [{_, _, [:IO]}, :inspect]} = node}, line),
    do: AST.starts_at?(node, line)

  def can_refactor?(_, _), do: false

  def refactor(%{node: io_inspect} = zipper, line) do
    case parent = Zipper.up(zipper) do
      %{node: {^io_inspect, _, [{id, _, _} = arg | _]}} when id != :__block__ ->
        Zipper.replace(parent, arg)

      %{node: {^io_inspect, _, [value | _]}} ->
        if match?(%{node: {:|>, _, _}}, Zipper.up(parent)),
          do: refactor(parent, line),
          else: Zipper.replace(parent, value)

      %{node: {^io_inspect, _, _}} ->
        refactor(parent, line)

      %{node: {:|>, _, [arg, ^io_inspect]}} ->
        Zipper.replace(parent, arg)

      %{node: {:/, _, [^io_inspect, {:__block__, _, _}]}} ->
        refactor(parent, line)

      %{node: {:&, _, [^io_inspect]}} ->
        Zipper.replace(parent, {:&, [], [{:&, [], [1]}]})
    end
  end
end
