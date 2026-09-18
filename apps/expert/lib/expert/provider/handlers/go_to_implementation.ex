defmodule Expert.Provider.Handlers.GoToImplementation do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentImplementation{params: %Structures.ImplementationParams{} = params},
        %Context{document: document, project: project}
      ) do
    case EngineApi.implementation(project, document, params.position) do
      {:ok, locations} ->
        {:ok, locations}

      {:error, reason} ->
        Logger.error("GoToImplementation failed: #{inspect(reason)}")
        {:ok, []}
    end
  end
end
