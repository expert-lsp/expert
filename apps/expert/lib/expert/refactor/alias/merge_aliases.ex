# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.MergeAliases do
  use Expert.Refactor,
    title: "Merge aliases",
    kind: "refactor.rewrite",
    works_on: :selection

  alias Expert.Refactor.Alias

  def can_refactor?(zipper, {:__block__, _, selected_aliases}) do
    cond do
      group_mergeable_aliases(selected_aliases) == [] ->
        :skip

      not Enum.all?(selected_aliases, &AST.go_to_node(zipper, &1)) ->
        :skip

      true ->
        true
    end
  end

  def can_refactor?(_, _), do: :skip

  def refactor(zipper, {_, _, aliases}) do
    aliases
    |> group_mergeable_aliases()
    |> Enum.reduce(zipper, fn [alias_ | duplicated] = aliases, zipper ->
      duplicated
      |> Enum.reduce(zipper, &Zipper.remove(AST.go_to_node(&2, &1)))
      |> AST.go_to_node(alias_)
      |> Zipper.replace({:alias, [], merge_aliases(aliases)})
    end)
  end

  defp group_mergeable_aliases(selected_aliases) do
    selected_aliases
    |> Stream.filter(fn
      {:alias, _, [{:__aliases__, _, [_root]} | _]} ->
        false

      {:alias, _, [_, opts]} ->
        not Enum.any?(opts, &match?({{_, _, [:as]}, _}, &1))

      {:alias, _, _} ->
        true

      _ ->
        false
    end)
    |> Enum.group_by(fn
      {:alias, _, [{{:., _, [{_, _, [root | _]}, _]}, _, _} | _]} ->
        root

      {:alias, _, [{:__aliases__, _, [root | _]} | _]} ->
        root
    end)
    |> Map.values()
    |> Enum.reject(&(length(&1) < 2))
  end

  defp merge_aliases(aliases) do
    aliases
    |> Zipper.zip()
    |> Zipper.traverse_while([], fn
      %{node: {:., _, _}} = zipper, declarations ->
        {:skip, zipper, declarations}

      %{node: {:__aliases__, _, _}} = zipper, declarations ->
        {:cont, zipper, [Alias.expand_declaration(zipper) | declarations]}

      zipper, declarations ->
        {:cont, zipper, declarations}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.sort()
    |> merge_declarations()
  end

  defp merge_declarations([[root | _] | _] = declarations, path \\ []) do
    cond do
      length(declarations) == 1 ->
        [{:__aliases__, [], List.first(declarations)}]

      Enum.any?(declarations, &(length(&1) == 1)) ->
        {single, multiple} = Enum.split_with(declarations, &(length(&1) == 1))

        [
          {
            {:., [], [{:__aliases__, [], path}, :{}]},
            [newlines: 1],
            Enum.map(single, &{:__aliases__, [], &1}) ++
              if(Enum.empty?(multiple),
                do: [],
                else: merge_declarations(multiple, [])
              )
          }
        ]

      Enum.all?(declarations, &List.starts_with?(&1, [root])) ->
        declarations
        |> Enum.map(&List.delete_at(&1, 0))
        |> merge_declarations(path ++ [root])

      true ->
        declarations
        |> Enum.group_by(&List.first/1)
        |> Map.values()
        |> Enum.map(&merge_declarations(&1, path))
        |> List.flatten()
    end
  end
end
