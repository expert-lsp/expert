# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Variable do
  alias Expert.Refactor.AST
  alias Expert.Refactor.Dataflow
  alias Sourceror.Zipper

  defguard is_variable(node)
           when is_tuple(node) and
                  tuple_size(node) == 3 and
                  is_atom(elem(node, 0)) and
                  elem(node, 0) not in ~w(binary _)a and
                  is_nil(elem(node, 2))

  def at_one?(%{node: node} = zipper) when is_variable(node),
    do: not match?(%{node: {:@, _, _}}, Zipper.up(zipper))

  def at_one?(_zipper), do: false

  def plain_variables?(nodes), do: Enum.all?(nodes, &is_variable/1)

  def inside_declaration?(%{node: node} = zipper) do
    case parent = Zipper.up(zipper) do
      %{node: {id, _, [^node, _]}} when id in ~w(def defp <- when =)a ->
        true

      %{node: {:->, _, [^node, _]}} ->
        cond do
          match?(%{node: {:fn, _, _}}, Zipper.up(parent)) -> true
          match?(%{node: {:case, _, _}}, AST.up(parent, 4)) -> true
          true -> false
        end

      %{node: {_, _, [_ | _]}} ->
        inside_declaration?(parent)

      %{node: [_ | _]} ->
        inside_declaration?(parent)

      %{node: {_, _}} ->
        inside_declaration?(parent)

      _ ->
        false
    end
  end

  def find_all_references(zipper, {name, _, _} = variable) do
    zipper
    |> Zipper.topmost_root()
    |> Dataflow.group_variables_semantically()
    |> Stream.map(fn {d, u} -> [d | u] end)
    |> Enum.find([], fn
      [{^name, _, _} | _] = references ->
        Enum.any?(references, &AST.equal?(&1, variable))

      _ ->
        false
    end)
  end

  def replace_variables_by_values(selection, variables, values, scope) do
    variable_groups = Dataflow.group_variables_semantically(scope)

    variables
    |> Stream.map(&variable_groups[&1])
    |> Stream.zip(values)
    |> Enum.reduce(
      Zipper.zip(selection),
      fn {usages, value}, zipper -> AST.replace_nodes(zipper, usages, value) end
    )
    |> Zipper.node()
  end

  # find &{i} usages and replace them with arg{i}
  def turn_captures_into_variables(node) do
    node
    |> Zipper.zip()
    |> Zipper.traverse(MapSet.new(), fn
      %{node: {:&, _, [i]}} = zipper, variables when is_number(i) ->
        arg = {String.to_atom("arg#{i}"), [], nil}
        {Zipper.replace(zipper, arg), MapSet.put(variables, arg)}

      zipper, variables ->
        {zipper, variables}
    end)
    |> then(fn {zipper, args} -> {zipper, Enum.to_list(args)} end)
  end
end
