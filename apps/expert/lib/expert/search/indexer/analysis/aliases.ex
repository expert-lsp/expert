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
  Returns a function that resolves one alias name, such as `[:Foo]`, the way
  `at/2` would at `position`, without building the map of every alias in scope.
  """
  @spec lookup(Analysis.t(), Position.t()) :: ([atom()] -> {:ok, module()} | :error)
  def lookup(%Analysis{} = analysis, %Position{} = position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{aliases: aliases} | _] -> &resolve(aliases, &1, position.line)
      [] -> fn _as -> :error end
    end
  end

  # `Scope.alias_map/2` keeps, for each name, the alias on the latest line not
  # after `line`, and of those on the same line the one declared first. Scope
  # aliases are listed from the latest declared, so later list entries win ties.
  defp resolve(aliases, as, line) do
    case latest_alias(aliases, as, line, nil) do
      %Alias{module: segments} = alias when is_list(segments) ->
        if Enum.all?(segments, &is_atom/1), do: {:ok, Alias.to_module(alias)}, else: :error

      _ ->
        :error
    end
  end

  defp latest_alias([], _as, _line, found), do: found

  defp latest_alias([%Alias{as: as, range: range} = alias | rest], as, line, found) do
    alias_line = range.start.line

    found =
      cond do
        alias_line > line -> found
        found == nil or alias_line >= found.range.start.line -> alias
        true -> found
      end

    latest_alias(rest, as, line, found)
  end

  defp latest_alias([_other | rest], as, line, found), do: latest_alias(rest, as, line, found)

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
