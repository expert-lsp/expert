defmodule Expert.Provider.Handlers.GoToDefinition do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Definition
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Delegation
  alias Expert.Integrations.SemanticMetadata.Entity
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
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

    result =
      with [] <- integration_definitions(project, document, params.position),
           {:ok, nil} <- Definition.definition(project, document, params.position) do
        engine_definition(project, document, params.position)
      else
        [_ | _] = locations -> {:ok, locations}
        {:ok, _location} = result -> result
      end

    case result do
      {:ok, _native_location} = result ->
        result

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp engine_definition(project, document, position) do
    with {:ok, _document, %Analysis{} = analysis} <- Document.Store.fetch(document.uri, :analysis),
         {:ok, entity, _range, entity_analysis, entity_position} <-
           Entity.resolve_by_integrations(project, analysis, position) do
      case EngineApi.entity_definition(project, entity_analysis, entity_position, entity) do
        {:ok, locations} when is_list(locations) ->
          {:ok, Enum.map(locations, &to_document(&1, analysis.document))}

        {:ok, %Location{} = location} ->
          {:ok, to_document(location, analysis.document)}

        other ->
          other
      end
    else
      _ -> EngineApi.definition(project, document, position)
    end
  end

  defp to_document(%Location{uri: uri} = location, %Document{uri: uri} = document),
    do: Location.new(Delegation.to_document_range(location.range, document), document)

  defp to_document(location, _document), do: location

  defp integration_definitions(project, document, position) do
    with {:ok, _document, %Analysis{} = analysis} <- Document.Store.fetch(document.uri, :analysis),
         {:ok, env} <- Env.new(project, analysis, position) do
      Integrations.definition(env)
    else
      _error -> []
    end
  end
end
