defmodule Expert.Provider.Handlers.GoToDefinition do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Definition
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata
  alias Expert.Integrations.SemanticMetadata.Delegation
  alias Expert.Integrations.SemanticMetadata.Entity
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentDefinition{params: %Structures.DefinitionParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context
    position = params.position

    result =
      case Document.Store.fetch(document.uri, :analysis) do
        {:ok, _document, %Analysis{} = analysis} ->
          cursor = SemanticMetadata.cursor(project, analysis, position)

          with [] <- SemanticMetadata.definition(cursor),
               :ignore <- resolved_definition(project, analysis, position, cursor),
               {:ok, nil} <- Definition.definition(project, document, position) do
            EngineApi.definition(project, document, position)
          else
            [_ | _] = locations -> {:ok, locations}
            result -> result
          end

        _error ->
          EngineApi.definition(project, document, position)
      end

    case result do
      {:ok, _native_location} = result ->
        result

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp resolved_definition(project, analysis, position, cursor) do
    case Entity.resolve_by_integrations(project, analysis, position, cursor) do
      {:ok, entity, _range, entity_analysis, entity_position} ->
        case EngineApi.entity_definition(project, entity_analysis, entity_position, entity) do
          {:ok, locations} when is_list(locations) ->
            {:ok,
             Enum.map(locations, &to_document(&1, entity_analysis.document, analysis.document))}

          {:ok, %Location{} = location} ->
            {:ok, to_document(location, entity_analysis.document, analysis.document)}

          other ->
            other
        end

      _error ->
        :ignore
    end
  end

  defp to_document(%Location{uri: uri} = location, delegated, %Document{uri: uri} = document),
    do: Location.new(Delegation.to_document_range(location.range, delegated, document), document)

  defp to_document(location, _delegated, _document), do: location
end
