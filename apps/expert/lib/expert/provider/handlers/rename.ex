defmodule Expert.Provider.Handlers.Rename do
  @moduledoc """
  Handler for textDocument/rename requests.

  This handler executes the rename operation and returns the workspace edit
  containing all the text edits and file renames needed.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Configuration
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Changes
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %GenLSP.Requests.TextDocumentRename{params: %Structures.RenameParams{} = params},
        %Context{document: document, project: project}
      ) do
    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, _document, %Ast.Analysis{valid?: true} = analysis} ->
        rename(project, analysis, params.position, params.new_name)

      _ ->
        {:error, :request_failed, "Document cannot be analyzed"}
    end
  end

  defp rename(project, analysis, position, new_name) do
    %Configuration{client_name: client_name} = Configuration.get()
    document_changes? = Configuration.client_support(:document_changes)

    rename_files? =
      document_changes? and
        "rename" in List.wrap(Configuration.client_support(:resource_operations))

    case EngineApi.rename(project, analysis, position, new_name, client_name, rename_files?) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, results} ->
        {:ok, to_workspace_edit(results, document_changes?)}

      {:error, {:unsupported_entity, entity}} ->
        Logger.info("Cannot rename entity: #{inspect(entity)}")
        {:ok, nil}

      {:error, reason} ->
        {:error, :request_failed, inspect(reason)}
    end
  end

  defp to_workspace_edit(results, true) do
    document_changes =
      Enum.flat_map(results, fn
        %Changes{rename_file: %Changes.RenameFile{}} = changes ->
          [to_text_document_edit(changes), to_rename_file(changes.rename_file)]

        %Changes{} = changes ->
          [to_text_document_edit(changes)]
      end)

    %Structures.WorkspaceEdit{document_changes: document_changes}
  end

  defp to_workspace_edit(results, false) do
    changes = Map.new(results, &{&1.document.uri, List.wrap(&1.edits)})
    %Structures.WorkspaceEdit{changes: changes}
  end

  defp to_text_document_edit(%Changes{} = changes) do
    %Changes{document: document, edits: edits, expected_version: expected_version} = changes

    text_document =
      %Structures.OptionalVersionedTextDocumentIdentifier{
        uri: document.uri,
        version: expected_version
      }

    %Structures.TextDocumentEdit{
      edits: edits,
      text_document: text_document
    }
  end

  defp to_rename_file(%Changes.RenameFile{} = rename_file) do
    %Structures.RenameFile{
      kind: "rename",
      new_uri: rename_file.new_uri,
      old_uri: rename_file.old_uri,
      options: %Structures.RenameFileOptions{overwrite: false}
    }
  end
end
