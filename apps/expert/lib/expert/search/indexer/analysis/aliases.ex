defmodule Expert.Search.Indexer.Analysis.Aliases do
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position

  @spec at(Analysis.t(), Position.t()) :: %{atom() => module()}
  def at(%Analysis{} = analysis, %Position{} = position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        scope
        |> Scope.alias_map(position)
        |> Enum.reduce(%{}, fn {as, %Alias{} = alias}, acc ->
          segments = alias.module

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

  @doc """
  Resolves an alias in the context of a line and a scope
  (used internally when calculating imports)
  """
  def resolve_at(%Scope{} = scope, module, line) do
    aliases = Scope.alias_map(scope, line)

    case module do
      # unquote(__MODULE__).SubModule
      [{:unquote, _, [{:__MODULE__, _, _}]} | suffix] ->
        resolve_current_module(aliases, suffix)

      [{:__MODULE__, _, _} | suffix] ->
        resolve_current_module(aliases, suffix)

      [prefix | suffix] ->
        case aliases do
          %{[^prefix] => _} ->
            resolve_alias(aliases, prefix, suffix)

          _ ->
            Module.concat(module)
        end
    end
  end

  defp resolve_current_module(aliases, suffix) do
    resolve_alias(aliases, :__MODULE__, suffix)
  end

  defp resolve_alias(aliases, prefix, suffix) do
    current_module =
      aliases
      |> Map.get(List.wrap(prefix))
      |> Alias.to_module()

    Module.concat([current_module | suffix])
  end
end
