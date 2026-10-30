# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias do
  alias Expert.Refactor.AST
  alias Expert.Refactor.Module
  alias Sourceror.Zipper

  @doc """
  alias Foo.Bar <- declaration
  Bar.bar()     <- usage
  """

  def inside_declaration?(zipper), do: AST.inside?(zipper, &match?({:alias, _, _}, &1))

  def contains_selection?(
        %{node: {:__aliases__, _, aliases} = node},
        {:__aliases__, _, selected_aliases} = selection
      ) do
    AST.starts_at?(node, AST.get_start_line(selection)) and
      List.starts_with?(aliases, selected_aliases)
  end

  def contains_selection?(_, _), do: false

  def new_declaration(refactored, alias_) do
    Module.place_node(
      refactored,
      alias_,
      fn nodes ->
        nodes
        |> Stream.with_index()
        |> Stream.map(fn
          {{id, _, _}, i} when id in ~w(use alias)a -> i + 1
          _ -> 0
        end)
        |> Enum.max()
      end
    )
  end

  def find_declaration(%{node: {_, _, [used_alias | _]}} = zipper) do
    zipper
    |> Zipper.top()
    |> Zipper.traverse(nil, fn
      %{node: {:alias, _, _} = node} = zipper, last_declaration ->
        if declaration = go_to_declaration(node, used_alias),
          do: {zipper, expand_declaration(declaration)},
          else: {zipper, last_declaration}

      zipper, declaration ->
        {zipper, declaration}
    end)
    |> elem(1)
  end

  def expand_declaration(zipper, path \\ []) do
    case zipper do
      %{node: {:__aliases__, _, aliases}} ->
        expand_declaration(Zipper.up(zipper), aliases ++ path)

      %{node: {{:., _, [{:__aliases__, _, aliases}, _]}, _, _}} ->
        expand_declaration(Zipper.up(zipper), aliases ++ path)

      %{node: {{:., _, [{:__MODULE__, _, _}, :{}]}, _, _}} ->
        [:__MODULE__ | path]

      %{node: {:alias, _, [{:__aliases__, _, aliases} | _]}} ->
        aliases ++ (path -- aliases)

      _ ->
        path
    end
  end

  defp go_to_declaration(node, used_alias) do
    node
    |> Zipper.zip()
    |> Zipper.traverse_while(nil, fn
      %{node: {:alias, _, [_, opts]}} = zipper, nil ->
        if Enum.any?(opts, &match?({{_, _, [:as]}, {_, _, [^used_alias]}}, &1)),
          do: {:halt, zipper, zipper},
          else: {:cont, zipper, nil}

      %{node: {:__aliases__, _, aliases}} = zipper, nil ->
        if List.last(aliases) == used_alias,
          do: {:halt, zipper, zipper},
          else: {:cont, zipper, nil}

      %{node: {:., _, [_, :{}]}} = zipper, nil ->
        {:skip, zipper, nil}

      zipper, nil ->
        {:cont, zipper, nil}
    end)
    |> elem(1)
  end
end
