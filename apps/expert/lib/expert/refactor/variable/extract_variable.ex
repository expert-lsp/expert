# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Variable.ExtractVariable do
  use Expert.Refactor,
    title: "Extract variable",
    kind: "refactor.extract",
    works_on: :selection

  alias Expert.Refactor.Function
  alias Expert.Refactor.IfElse
  alias Expert.Refactor.NameCache
  alias Expert.Refactor.Variable

  @variable_name "extracted_variable"

  def can_refactor?(%{node: {id, _, _}}, _)
      when id in ~w(alias __aliases__)a,
      do: false

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      Variable.inside_declaration?(zipper) ->
        false

      inside_function_reference_capture?(zipper) ->
        false

      invalid_parent?(zipper) ->
        false

      true ->
        true
    end
  end

  def refactor(zipper, selection), do: refactor(zipper, [], selection)

  defp refactor(%{node: node} = zipper, selection_path, selection) do
    refactor_parent(Zipper.up(zipper), zipper, node, selection_path, selection)
  end

  defp refactor_parent(
         %{node: {:->, _, [args, parent_node]}} = parent,
         _zipper,
         node,
         selection_path,
         selection
       )
       when parent_node == node do
    parent
    |> Zipper.replace(
      {:->, [], [args, extract_and_assign(parent, [node], 0, selection_path, selection)]}
    )
    |> AST.go_to_node(selection)
  end

  # selection is inside a COND clause
  defp refactor_parent(
         %{node: {:->, _, [parent_node, _]}} = parent,
         zipper,
         node,
         selection_path,
         selection
       )
       when parent_node == node do
    %{node: {:cond, _, _}} = zipper_at_cond = AST.up(parent, 4)

    refactor(
      zipper_at_cond,
      Zipper.path_to_ancestor(zipper, zipper_at_cond) ++ selection_path,
      selection
    )
  end

  defp refactor_parent(
         %{node: {:__block__, meta, statements}} = parent,
         zipper,
         _node,
         selection_path,
         selection
       ) do
    if meta[:closing] do
      refactor(parent, Zipper.path_to_ancestor(zipper, parent) ++ selection_path, selection)
    else
      [statement_index] = Zipper.path_to_ancestor(zipper, parent)

      parent
      |> Zipper.replace(
        extract_and_assign(parent, statements, statement_index, selection_path, selection)
      )
      |> AST.go_to_node(selection)
    end
  end

  defp refactor_parent(
         %{node: {{:__block__, _, [tag]}, parent_node}} = parent,
         _zipper,
         node,
         selection_path,
         selection
       )
       when tag in ~w(do else)a and parent_node == node do
    upper_structure = AST.up(parent, 2)
    line = AST.get_start_line(upper_structure.node)

    refactored =
      cond do
        Function.UseRegularSyntax.can_refactor?(upper_structure, line) ->
          upper_structure
          |> Function.UseRegularSyntax.refactor(line)
          |> AST.go_to_node(node)
          |> refactor(selection_path, selection)

        IfElse.UseRegularSyntax.can_refactor?(upper_structure, line) ->
          upper_structure
          |> IfElse.UseRegularSyntax.refactor(line)
          |> AST.go_to_node(node)
          |> refactor(selection_path, selection)

        true ->
          Zipper.update(parent, fn {block, statement} ->
            {block, extract_and_assign(parent, [statement], 0, selection_path, selection)}
          end)
      end

    AST.go_to_node(refactored, selection)
  end

  # same pattern matching as ExpandAnonymousFunction.can_refactor?/2
  defp refactor_parent(
         %{node: {:&, _, [body]}} = parent,
         _zipper,
         _node,
         selection_path,
         selection
       )
       when not is_number(body) do
    {%{node: new_selection}, _} = Variable.turn_captures_into_variables(selection)

    parent
    |> Function.ExpandAnonymousFunction.refactor(parent.node)
    |> Zipper.down()
    |> Zipper.down()
    |> Zipper.right()
    |> refactor(selection_path, new_selection)
  end

  defp refactor_parent(parent, zipper, _node, selection_path, selection) do
    refactor(parent, Zipper.path_to_ancestor(zipper, parent) ++ selection_path, selection)
  end

  defp extract_and_assign(zipper, statements, statement_index, selection_path, selection) do
    {before, [_ | rest]} = Enum.split(statements, statement_index)
    statement = Enum.at(statements, statement_index)

    variable = {next_available_name(zipper), [], nil}
    assignment = {:=, [], [variable, selection]}
    new_statement = replace_selection_by_variable(statement, selection_path, variable)

    {:__block__, [], before ++ [assignment, new_statement | rest]}
  end

  defp next_available_name(zipper) do
    NameCache.consume_name_or(fn ->
      zipper
      |> Zipper.top()
      |> Zipper.traverse([0], fn
        %{node: {id, _, nil}} = zipper, used_numbers when is_atom(id) ->
          {
            zipper,
            case Regex.run(~r/#{@variable_name}(\d*)/, Atom.to_string(id)) do
              [_, ""] ->
                [1 | used_numbers]

              [_, i] ->
                [String.to_integer(i) | used_numbers]

              _ ->
                used_numbers
            end
          }

        zipper, used_numbers ->
          {zipper, used_numbers}
      end)
      |> elem(1)
      |> Enum.max()
      |> then(&"#{@variable_name}#{if &1 == 0, do: "", else: &1 + 1}")
      |> String.to_atom()
    end)
  end

  defp replace_selection_by_variable(_statement, [], variable), do: variable

  defp replace_selection_by_variable(statement, selection_path, variable) do
    statement
    |> Zipper.zip()
    |> Zipper.follow_path(selection_path)
    |> Zipper.replace(variable)
    |> Zipper.top()
    |> Zipper.node()
  end

  defp invalid_parent?(%{node: node} = zipper) do
    case Zipper.up(zipper) do
      %{node: {:|>, _, [_, ^node]}} ->
        true

      %{node: {:@, _, [^node]}} ->
        true

      _ ->
        false
    end
  end

  defp inside_function_reference_capture?(%{node: {:&, _, [slash]}}),
    do: function_reference_slash?(slash)

  defp inside_function_reference_capture?(%{node: node} = zipper) do
    parent = Zipper.up(zipper)

    case parent do
      %{node: {:&, _, [^node]}} ->
        function_reference_slash?(node)

      %{node: {:/, _, [function, ^node]} = slash} ->
        function_reference?(function) and parent_is_capture?(parent, slash)

      %{node: {:/, _, [^node, {:__block__, _, [arity]}]} = slash} when is_integer(arity) ->
        function_reference?(node) and parent_is_capture?(parent, slash)

      _ ->
        false
    end
  end

  defp function_reference_slash?({:/, _, [function, {:__block__, _, [arity]}]})
       when is_integer(arity),
       do: function_reference?(function)

  defp function_reference_slash?(_), do: false

  defp parent_is_capture?(%{node: node} = zipper, node) do
    case Zipper.up(zipper) do
      %{node: {:&, _, [^node]}} -> true
      _ -> false
    end
  end

  defp function_reference?({:&, _, [arg]}) when is_integer(arg), do: false
  defp function_reference?(_), do: true
end
