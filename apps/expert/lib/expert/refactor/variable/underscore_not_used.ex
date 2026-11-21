# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Variable.UnderscoreNotUsed do
  use Expert.Refactor,
    title: "Underscore variables not used",
    kind: "quickfix",
    works_on: :line

  alias Expert.Refactor.Dataflow

  def can_refactor?(%{node: node}, line) do
    start_line = AST.get_start_line(node)
    end_line = AST.get_end_line(node)

    if line < start_line or end_line < line do
      :skip
    else
      variables = Dataflow.group_variables_semantically(node)

      cond do
        Enum.any?(variables, &can_underline?(&1, line)) ->
          true

        variables == %{} ->
          false

        true ->
          :skip
      end
    end
  end

  def refactor(%{node: node} = zipper, line) do
    node
    |> Dataflow.group_variables_semantically()
    |> Stream.filter(&same_line_and_no_usages?(&1, line))
    |> Enum.reduce(zipper, fn
      {declaration, []}, zipper ->
        zipper
        |> AST.go_to_node(declaration)
        |> Zipper.update(fn {name, meta, nil} ->
          {String.to_atom("_#{name}"), meta, nil}
        end)
    end)
  end

  defp can_underline?({{name, _, _} = declaration, []}, line) do
    AST.starts_at?(declaration, line) and
      not String.starts_with?("#{name}", "_")
  end

  defp can_underline?(_, _), do: false

  defp same_line_and_no_usages?({declaration, usages}, line),
    do: AST.starts_at?(declaration, line) and usages == []
end
