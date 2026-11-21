# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Pipeline.IntroducePipe do
  use Expert.Refactor,
    title: "Introduce pipe",
    kind: "refactor.rewrite",
    works_on: :line

  import Sourceror.Identifier

  def can_refactor?(%{node: {_, _, []}}, _), do: false

  def can_refactor?(%{node: {id, _, _}}, _)
      when id in [:%{}, :{}, :__block__, :fn],
      do: false

  def can_refactor?(%{node: {:alias, _, _}}, _),
    do: :skip

  def can_refactor?(%{node: {_, _, _} = node} = zipper, line) do
    cond do
      not AST.starts_at?(node, line) ->
        false

      not can_pipe_into?(node) ->
        false

      invalid_parent?(zipper) ->
        false

      true ->
        true
    end
  end

  def can_refactor?(_, _), do: false

  def refactor(zipper, _) do
    zipper
    |> Zipper.update(fn {id, meta, [arg | rest]} ->
      {:|>, [], [arg, {id, meta, rest}]}
    end)
  end

  defp invalid_parent?(%{node: {function_id, _, _}} = zipper) do
    zipper
    |> Zipper.up()
    |> then(fn
      # function is already receiving first argument from a pipe
      %{node: {:|>, _, [_, {^function_id, _, _}]}} ->
        true

      # parent is part of function declaration
      %{node: {parent_id, _, _}} when parent_id in [:def, :defp, :when] ->
        true

      _ ->
        false
    end)
  end

  defp can_pipe_into?({{:., _, [Kernel, :to_string]}, _, _}), do: false
  defp can_pipe_into?({{:., _, [Access | _]}, _, _}), do: false
  defp can_pipe_into?({:., _, [Access | _]}), do: false
  defp can_pipe_into?({:case, _, _}), do: true

  defp can_pipe_into?({_, meta, _} = node),
    do: !!meta[:closing] and is_call(node)
end
