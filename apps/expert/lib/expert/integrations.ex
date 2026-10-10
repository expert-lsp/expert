defmodule Expert.Integrations do
  @moduledoc """
  Registers built-in integrations.
  """

  alias Forge.Ast.Env
  alias Forge.Document.Location
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @callback index(Project.t(), binary(), map(), String.t()) :: [Entry.t()]

  @callback complete(Env.t()) ::
              {:augment | :override, [{struct(), [atom()]}], boolean(), [atom()]}
              | {:delegate, %{source: String.t()}}
              | :ignore

  @callback hover(Env.t()) :: [{String.t(), Range.t() | nil}]

  @callback definition(Env.t()) :: [Location.t()]

  @callback resolve(Env.t()) ::
              {:entity, map(), Range.t() | nil} | {:delegate, %{source: String.t()}} | :ignore

  @callback references(Project.t(), entity :: tuple()) :: [Location.t()]

  @callback signature_help(Env.t()) :: [map()] | :ignore

  @optional_callbacks index: 4,
                      complete: 1,
                      hover: 1,
                      definition: 1,
                      resolve: 1,
                      references: 2,
                      signature_help: 1

  @indexers [
    {Expert.Integrations.SemanticMetadata.Indexer, 1},
    {Expert.Integrations.Spark.Indexer, 1}
  ]

  @completion_providers [Expert.Integrations.SemanticMetadata.Completion]
  @hover_providers [Expert.Integrations.SemanticMetadata.Hover]

  @definition_providers [Expert.Integrations.SemanticMetadata.Definition]

  @resolve_providers [Expert.Integrations.SemanticMetadata.Resolve]

  @references_providers [Expert.Integrations.SemanticMetadata.References]

  @signature_help_providers [Expert.Integrations.SemanticMetadata.SignatureHelp]

  @indexer_versions @indexers
                    |> Enum.map(fn {module, version} -> {Atom.to_string(module), version} end)
                    |> Enum.sort()

  def indexer_versions, do: @indexer_versions

  def index_beam(project, binary, metadata, source_path) do
    Enum.flat_map(@indexers, fn {indexer, _version} ->
      indexer.index(project, binary, metadata, source_path)
    end)
  end

  def complete(env), do: first_result(@completion_providers, & &1.complete(env))

  def hover(env) do
    Enum.flat_map(@hover_providers, & &1.hover(env))
  end

  def definition(env), do: Enum.flat_map(@definition_providers, & &1.definition(env))

  def resolve(env), do: first_result(@resolve_providers, & &1.resolve(env))

  def references(project, entity),
    do: Enum.flat_map(@references_providers, & &1.references(project, entity))

  def signature_help(env), do: first_result(@signature_help_providers, & &1.signature_help(env))

  defp first_result(providers, call) do
    Enum.find_value(providers, :ignore, fn provider ->
      case call.(provider) do
        :ignore -> nil
        result -> result
      end
    end)
  end
end
