defmodule Expert.Search.Indexer.Analysis.Aliases do
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position

  @type in_scope :: {[Alias.t()], pos_integer()}

  @spec in_scope(Analysis.t(), Position.t()) :: in_scope()
  def in_scope(%Analysis{} = analysis, %Position{} = position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{aliases: aliases} | _] -> {aliases, position.line}
      [] -> {[], position.line}
    end
  end

  @spec fetch(in_scope(), [atom()]) :: {:ok, module()} | :error
  def fetch({aliases, line}, as), do: resolve(aliases, as, line)

  defp resolve(aliases, as, line) do
    case latest_alias(aliases, as, line) do
      %Alias{module: segments} = alias when is_list(segments) ->
        if Enum.all?(segments, &is_atom/1), do: {:ok, Alias.to_module(alias)}, else: :error

      _ ->
        :error
    end
  end

  # aliases are stored newest first
  defp latest_alias(aliases, as, line) do
    Enum.find(aliases, fn %Alias{} = alias ->
      alias.as == as and alias.range.start.line <= line
    end)
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
