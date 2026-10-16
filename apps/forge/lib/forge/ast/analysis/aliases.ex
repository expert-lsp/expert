defmodule Forge.Ast.Analysis.Aliases do
  @moduledoc false

  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position

  def at(%Analysis{} = analysis, %Position{} = position) do
    scope_aliases = scope_aliases(analysis, position)

    case Analysis.cursor_env_at(analysis, position) do
      %{aliases: aliases} -> Map.merge(scope_aliases, aliases)
      nil -> scope_aliases
    end
  end

  def resolve_at(%Scope{} = scope, module, position) do
    aliases = Scope.alias_map(scope, position)

    case module do
      [{:unquote, _, [{:__MODULE__, _, _}]} | suffix] ->
        resolve_alias(aliases, :__MODULE__, suffix)

      [{:__MODULE__, _, _} | suffix] ->
        resolve_alias(aliases, :__MODULE__, suffix)

      [prefix | suffix] ->
        if Map.has_key?(aliases, [prefix]) do
          resolve_alias(aliases, prefix, suffix)
        else
          Module.concat(module)
        end
    end
  end

  defp scope_aliases(analysis, position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        scope
        |> Scope.alias_map(position)
        |> Enum.reduce(%{}, fn {as, %Alias{module: segments} = alias}, acc ->
          if is_list(segments) and Enum.all?(segments, &is_atom/1) do
            Map.put(acc, as, Alias.to_module(alias))
          else
            acc
          end
        end)

      [] ->
        %{}
    end
  end

  defp resolve_alias(aliases, prefix, suffix) do
    current_module = aliases |> Map.fetch!(List.wrap(prefix)) |> Alias.to_module()
    Module.concat([current_module | suffix])
  end
end
