defmodule Expert.Integrations.SemanticMetadata.Entity do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Delegation
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project

  def resolve(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    case resolve_by_integrations(project, analysis, position) do
      {:ok, entity, range, _analysis, _position} -> {:ok, entity, range}
      :ignore -> EngineApi.resolve_entity(project, analysis, position)
      error -> error
    end
  end

  def resolve_by_integrations(
        %Project{} = project,
        %Analysis{} = analysis,
        %Position{} = position
      ) do
    case Env.new(project, analysis, position) do
      {:ok, env} -> resolution(Integrations.resolve(env), project, analysis, position)
      _error -> :ignore
    end
  end

  defp resolution({:entity, entity, range}, _project, analysis, position),
    do: {:ok, to_engine(entity), range || Range.new(position, position), analysis, position}

  defp resolution({:delegate, %{source: source}}, project, analysis, position) do
    {delegated, delegated_position} = Delegation.analyze(analysis, source, position)

    with {:ok, entity, range} <- EngineApi.resolve_entity(project, delegated, delegated_position) do
      {:ok, entity, Delegation.to_document_range(range, analysis.document), delegated,
       delegated_position}
    end
  end

  defp resolution(:ignore, _project, _analysis, _position), do: :ignore

  def to_spec(_project, {kind, module}) when kind in [:module, :struct],
    do: %{kind: kind, module: module}

  def to_spec(project, {:call, module, name, arity}) do
    kind =
      case ModuleRegistry.module_exports(project, module) do
        {:ok, %{macros: macros}} -> if {name, arity} in macros, do: :macro, else: :function
        :error -> :function
      end

    %{kind: kind, module: module, name: name, arity: arity}
  end

  def to_spec(_project, {:type, module, name, arity}),
    do: %{kind: :type, module: module, name: name, arity: arity}

  def to_spec(_project, _entity), do: nil

  defp to_engine(%{kind: kind, module: module}) when kind in [:module, :struct],
    do: {kind, module}

  defp to_engine(%{kind: kind, module: module, name: name, arity: arity})
       when kind in [:function, :macro],
       do: {:call, module, name, arity}

  defp to_engine(%{kind: :type, module: module, name: name, arity: arity}),
    do: {:type, module, name, arity}
end
