# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.ExtractAnonymousFunction do
  use Expert.Refactor,
    title: "Extract anonymous function",
    kind: "refactor.extract",
    works_on: :selection

  alias Expert.Refactor.Dataflow
  alias Expert.Refactor.Function
  alias Expert.Refactor.Module

  @function_name "extracted_function"

  def can_refactor?(%{node: {:fn, _, [{:->, _, [[] | _]}]}}, _), do: false

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      not Function.anonymous?(node) ->
        false

      not Module.inside_one?(zipper) ->
        false

      already_extracted_function?(node) ->
        :skip

      true ->
        true
    end
  end

  def refactor(%{node: {:&, _, _}} = zipper, _) do
    zipper
    |> Function.ExpandAnonymousFunction.refactor(nil)
    |> refactor(nil)
  end

  def refactor(%{node: {:fn, _, clauses} = node} = zipper, _) do
    [{:->, _, [args, _]} | _] = clauses

    name = Function.next_available_function_name(zipper, @function_name)
    outer_variables = Dataflow.outer_variables(node)

    args = for i <- 1..length(args), do: {:&, [], [i]}
    args = args ++ outer_variables

    zipper
    |> Zipper.replace({:&, [], [{name, [], args}]})
    |> add_private_functions(clauses, name, outer_variables)
  end

  defp add_private_functions(zipper, clauses, name, outer_variables) do
    Enum.reduce(
      clauses,
      zipper,
      fn {:->, _, [args, body]}, zipper ->
        Function.new_private_function(zipper, name, args ++ outer_variables, body)
      end
    )
  end

  defp already_extracted_function?({_, _, [{name, _, _} | _]})
       when is_atom(name),
       do: String.starts_with?(Atom.to_string(name), @function_name)

  defp already_extracted_function?(_), do: false
end
