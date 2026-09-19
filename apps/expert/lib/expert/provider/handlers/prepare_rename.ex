defmodule Expert.Provider.Handlers.PrepareRename do
  @moduledoc """
  Handler for textDocument/prepareRename requests.

  This handler determines if the entity at the cursor can be renamed
  and returns the range and placeholder text for the rename operation.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(
        %GenLSP.Requests.TextDocumentPrepareRename{
          params: %Structures.PrepareRenameParams{} = params
        },
        %Context{document: document, project: project}
      ) do
    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, _document, %Ast.Analysis{valid?: true} = analysis} ->
        prepare_rename(project, analysis, params.position)

      _ ->
        {:error, :request_failed, "Document cannot be analyzed"}
    end
  end

  defp prepare_rename(project, analysis, position) do
    case EngineApi.prepare_rename(project, analysis, position) do
      {:ok, placeholder, range} when is_binary(placeholder) ->
        # PrepareRenameResult is a type alias in GenLSP, return as map
        result = %{
          placeholder: placeholder,
          range: range
        }

        {:ok, result}

      {:ok, nil} ->
        {:ok, nil}

      {:error, error} when is_binary(error) ->
        {:error, :request_failed, error}

      {:error, error} ->
        {:error, :request_failed, inspect(error)}
    end
  end
end
