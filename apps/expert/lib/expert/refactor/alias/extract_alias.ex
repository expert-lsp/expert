# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Alias.ExtractAlias do
  use Expert.Refactor,
    title: "Extract alias",
    kind: "refactor.extract",
    works_on: :selection

  alias Expert.Refactor.Alias
  alias Expert.Refactor.Module

  def can_refactor?(
        %{node: {:__aliases__, _, _}} = zipper,
        {:__aliases__, _, [_, _ | _] = selected_aliases} = selection
      ) do
    cond do
      not Alias.contains_selection?(zipper, selection) ->
        false

      not Module.inside_one?(zipper) ->
        false

      Alias.inside_declaration?(zipper) ->
        false

      name_conflict?(zipper, selected_aliases) ->
        false

      true ->
        true
    end
  end

  def can_refactor?(_, _), do: false

  def refactor(zipper, {_, _, selected_aliases}) do
    refactored = extract_alias(zipper, selected_aliases)

    case Alias.find_declaration(refactored) do
      ^selected_aliases ->
        refactored

      nil ->
        alias_ = {:alias, [], [{:__aliases__, [], selected_aliases}]}
        Alias.new_declaration(refactored, alias_)
    end
  end

  defp extract_alias(zipper, selected_aliases) do
    Zipper.update(zipper, fn {:__aliases__, meta, aliases} ->
      {:__aliases__, meta, Enum.drop(aliases, length(selected_aliases) - 1)}
    end)
  end

  defp name_conflict?(zipper, selected_aliases) do
    zipper
    |> extract_alias(selected_aliases)
    |> Alias.find_declaration()
    |> then(fn
      ^selected_aliases -> false
      nil -> false
      _other_declaration -> true
    end)
  end
end
