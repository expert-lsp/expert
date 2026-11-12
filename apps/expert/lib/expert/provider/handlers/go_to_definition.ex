defmodule Expert.Provider.Handlers.GoToDefinition do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Definition
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Project.Store
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def requires_engine?, do: false

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentDefinition{params: %Structures.DefinitionParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    result =
      case Definition.definition(project, document, params.position) do
        {:ok, nil} -> fallback_to_engine(project, document, params.position)
        {:ok, _native_location} = result -> result
      end

    case result do
      {:ok, _native_location} = result ->
        result

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp fallback_to_engine(project, document, position) do
    if Store.ready?(project) do
      EngineApi.definition(project, document, position)
    else
      {:ok, nil}
    end
  end
end
