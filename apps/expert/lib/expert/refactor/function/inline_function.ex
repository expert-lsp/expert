# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function.InlineFunction do
  use Expert.Refactor,
    title: "Inline function",
    kind: "refactor.inline",
    works_on: :selection

  alias Expert.Refactor.Function
  alias Expert.Refactor.Module
  alias Expert.Refactor.Variable

  def can_refactor?(zipper, {:&, _, [body]}), do: can_refactor?(zipper, body)

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      not Module.inside_one?(zipper) ->
        false

      not Function.call?(node) ->
        false

      zipper |> Zipper.up() |> Zipper.node() |> Function.definition?() ->
        false

      Enum.empty?(Function.find_definitions(zipper)) ->
        false

      true ->
        true
    end
  end

  def refactor(%{node: {name, _, call_values} = node} = zipper, _) do
    parent = Zipper.up(zipper)
    statements = statements_to_inline(zipper)

    cond do
      match?(%{node: {:|>, _, [_, ^node]}}, parent) ->
        rebuilt_call = {name, [], [{:&, [], [1]} | call_values]}

        zipper
        |> Zipper.replace({:then, [], [{:&, [], [rebuilt_call]}]})
        |> AST.go_to_node(rebuilt_call)
        |> refactor(nil)

      match?(%{node: {:&, _, [{:/, _, _}]}}, parent) ->
        parent
        |> Function.ExpandAnonymousFunction.refactor(parent.node)
        |> then(fn %{node: {:fn, _, [{:->, _, [_, body]}]}} = zipper ->
          zipper
          |> AST.go_to_node(body)
          |> refactor(nil)
        end)
        |> maybe_collapse_anonymous_function()

      AST.inside?(zipper, &match?({:&, _, _}, &1)) ->
        zipper
        |> ensure_expanded_scope()
        |> refactor(nil)
        |> maybe_collapse_anonymous_function()

      not match?(%{node: {:__block__, _, _}}, parent) and length(statements) > 1 ->
        extract_and_reassign_then_inline(zipper, statements)

      true ->
        zipper
        |> ensure_expanded_scope()
        |> inline_statements_before_node(statements)
        |> Zipper.remove()
    end
  end

  defp extract_and_reassign_then_inline(%{node: node} = zipper, statements) do
    {statements, [last_statement]} = Enum.split(statements, -1)

    zipper
    |> Variable.ExtractVariable.refactor(node)
    |> AST.go_to_node(node)
    |> Zipper.up()
    |> Zipper.update(fn {:=, _, [v, _]} -> {:=, [], [v, last_statement]} end)
    |> inline_statements_before_node(statements)
    |> AST.go_to_node(last_statement)
    |> Variable.InlineVariable.refactor(nil)
  end

  defp inline_statements_before_node(zipper, statements),
    do: Enum.reduce(statements, zipper, &Zipper.insert_left(&2, &1))

  defp statements_to_inline(%{node: {_, _, call_values}} = zipper) do
    case Function.find_definitions(zipper) do
      [{_, _, [{:when, _, _}, _]} = guarded_definition] ->
        merge_definitions_as_case_statement([guarded_definition], call_values)

      [{_, _, [{_, _, args}, [{_, body}]]} = single_definition] ->
        args = args || []

        statements =
          case body do
            {:__block__, _, statements} -> statements
            statement -> [statement]
          end

        if Variable.plain_variables?(args) do
          Variable.replace_variables_by_values(
            statements,
            args,
            call_values,
            single_definition
          )
        else
          [{:=, [], [{:{}, [], args}, {:{}, [], call_values}]} | statements]
        end

      definitions ->
        merge_definitions_as_case_statement(definitions, call_values)
    end
  end

  defp merge_definitions_as_case_statement(definitions, call_values) do
    [
      {:case, [do: [], end: []],
       [
         {:{}, [], call_values},
         [
           {{:__block__, [], [:do]},
            Enum.map(
              definitions,
              fn
                {_, _, [{:when, _, [{_, _, args}, guard]}, [{_, body}]]} ->
                  {:->, [], [[{:when, [], [{:{}, [], args}, guard]}], body]}

                {_, _, [{_, _, args}, [{_, body}]]} ->
                  {:->, [], [[{:{}, [], args}], body]}
              end
            )}
         ]
       ]}
    ]
  end

  defp ensure_expanded_scope(%{node: node} = zipper) do
    zipper
    |> Variable.ExtractVariable.refactor(node)
    |> Variable.InlineVariable.refactor(nil)
  end

  defp maybe_collapse_anonymous_function(zipper) do
    zipper
    |> AST.up_until(&match?({:fn, _, _}, &1))
    |> then(
      &if Function.CollapseAnonymousFunction.can_refactor?(&1, &1.node),
        do: Function.CollapseAnonymousFunction.refactor(&1, nil),
        else: zipper
    )
  end
end
