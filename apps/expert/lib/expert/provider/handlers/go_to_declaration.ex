defmodule Expert.Provider.Handlers.GoToDeclaration do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentDeclaration{params: %Structures.DeclarationParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    case EngineApi.declaration(project, document, params.position) do
      {:ok, native_location} ->
        {:ok, native_location}

      {:error, reason} ->
        Logger.error("GoToDeclaration failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
