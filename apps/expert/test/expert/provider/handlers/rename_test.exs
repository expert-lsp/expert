defmodule Expert.Provider.Handlers.RenameTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Configuration
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Changes
  alias GenLSP.Requests
  alias GenLSP.Structures

  setup_all do
    start_supervised(Expert.Application.document_store_child_spec())
    :ok
  end

  setup do
    set_workspace_edit_support(true, ["rename"])

    project = project()
    uri = subject_uri(project, "lib/my_app/users.ex")

    if Document.Store.open?(uri), do: Document.Store.close(uri)

    text = "defmodule MyApp.Users do\n  \"😀\"; MyApp.Users.run()\nend\n"
    :ok = Document.Store.open(uri, text, 1)
    {:ok, document} = Document.Store.fetch(uri)

    on_exit(fn ->
      :persistent_term.erase(Configuration)
      if Document.Store.open?(uri), do: Document.Store.close(uri)
    end)

    {:ok, project: project, document: document}
  end

  test "emits a safe file rename when the client supports it", %{
    project: project,
    document: document
  } do
    new_uri = subject_uri(project, "lib/my_app/accounts.ex")
    rename_file = Changes.RenameFile.new(document.uri, new_uri)
    changes = changes(document, [], document.version, rename_file)
    test_pid = self()

    patch(EngineApi, :rename, fn _project, _analysis, _position, _name, _client, rename_files? ->
      send(test_pid, {:rename_files?, rename_files?})
      {:ok, [changes]}
    end)

    context = Context.new(document.uri, document, project)

    assert {:ok,
            %Structures.WorkspaceEdit{
              document_changes: [
                %Structures.TextDocumentEdit{},
                %Structures.RenameFile{
                  options: %Structures.RenameFileOptions{overwrite: false}
                }
              ]
            }} = Handlers.Rename.handle(rename_request(document.uri), context)

    assert_receive {:rename_files?, true}
  end

  test "converts rename edit ranges to UTF-16", %{project: project, document: document} do
    range = unicode_range(document)
    edit = Document.Edit.new("MyApp.Accounts", range)
    patch(EngineApi, :rename, {:ok, [changes(document, [edit], document.version)]})

    context = Context.new(document.uri, document, project)
    assert {:ok, workspace_edit} = Handlers.Rename.handle(rename_request(document.uri), context)
    assert {:ok, converted} = Convert.to_lsp(workspace_edit)

    assert [
             %Structures.TextDocumentEdit{
               edits: [%Structures.TextEdit{range: converted_range}]
             }
           ] = converted.document_changes

    assert converted_range.start.character == 8
    assert converted_range.end.character == 19
  end

  test "converts prepare rename ranges to UTF-16", %{project: project, document: document} do
    patch(EngineApi, :prepare_rename, {:ok, "MyApp.Users", unicode_range(document)})
    context = Context.new(document.uri, document, project)

    request = %Requests.TextDocumentPrepareRename{
      id: Expert.Protocol.Id.next(),
      params: %Structures.PrepareRenameParams{
        text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
        position: %Structures.Position{line: 1, character: 8}
      }
    }

    assert {:ok, result} = Handlers.PrepareRename.handle(request, context)
    assert {:ok, converted} = Convert.to_lsp(result)
    assert converted.range.start.character == 8
    assert converted.range.end.character == 19
  end

  test "uses the captured version after the open document changes", %{
    project: project,
    document: document
  } do
    edit = Document.Edit.new("MyApp.Accounts", unicode_range(document))
    patch(EngineApi, :rename, {:ok, [changes(document, [edit], document.version)]})

    assert :ok =
             Document.Store.update(document.uri, fn current ->
               {:ok, %{current | version: current.version + 1}}
             end)

    context = Context.new(document.uri, document, project)
    assert {:ok, workspace_edit} = Handlers.Rename.handle(rename_request(document.uri), context)

    assert [%Structures.TextDocumentEdit{text_document: %{version: 1}}] =
             workspace_edit.document_changes
  end

  test "omits the synthetic version for a temporary document", %{
    project: project,
    document: document
  } do
    temporary = Document.new("file:///closed.ex", "defmodule Closed do\nend\n", 0)
    edit = Document.Edit.new("Accounts", unicode_range(document))
    patch(EngineApi, :rename, {:ok, [changes(temporary, [edit], nil)]})

    context = Context.new(document.uri, document, project)
    assert {:ok, workspace_edit} = Handlers.Rename.handle(rename_request(document.uri), context)

    assert [%Structures.TextDocumentEdit{text_document: %{version: nil}}] =
             workspace_edit.document_changes
  end

  test "uses plain changes when document changes are unsupported", %{
    project: project,
    document: document
  } do
    Configuration.new() |> Configuration.set()
    edit = Document.Edit.new("MyApp.Accounts", unicode_range(document))
    result = changes(document, [edit], document.version)
    test_pid = self()

    patch(EngineApi, :rename, fn _project, _analysis, _position, _name, _client, rename_files? ->
      send(test_pid, {:rename_files?, rename_files?})
      {:ok, [result]}
    end)

    context = Context.new(document.uri, document, project)
    assert {:ok, workspace_edit} = Handlers.Rename.handle(rename_request(document.uri), context)
    assert {:ok, converted} = Convert.to_lsp(workspace_edit)
    uri = document.uri

    assert %{^uri => [%Structures.TextEdit{}]} = converted.changes
    assert is_nil(converted.document_changes)
    assert_receive {:rename_files?, false}
  end

  test "does not rename files without rename resource operation support", %{
    project: project,
    document: document
  } do
    set_workspace_edit_support(true, nil)
    edit = Document.Edit.new("MyApp.Accounts", unicode_range(document))
    result = changes(document, [edit], document.version)
    test_pid = self()

    patch(EngineApi, :rename, fn _project, _analysis, _position, _name, _client, rename_files? ->
      send(test_pid, {:rename_files?, rename_files?})
      {:ok, [result]}
    end)

    context = Context.new(document.uri, document, project)
    assert {:ok, workspace_edit} = Handlers.Rename.handle(rename_request(document.uri), context)
    assert [%Structures.TextDocumentEdit{}] = workspace_edit.document_changes
    assert_receive {:rename_files?, false}
  end

  defp changes(document, edits, expected_version, rename_file \\ nil) do
    Changes.new(document, edits, rename_file, expected_version)
  end

  defp rename_request(uri) do
    %Requests.TextDocumentRename{
      id: Expert.Protocol.Id.next(),
      params: %Structures.RenameParams{
        text_document: %Structures.TextDocumentIdentifier{uri: uri},
        position: %Structures.Position{line: 0, character: 10},
        new_name: "MyApp.Accounts"
      }
    }
  end

  defp set_workspace_edit_support(document_changes, resource_operations) do
    %Structures.ClientCapabilities{
      workspace: %Structures.WorkspaceClientCapabilities{
        workspace_edit: %Structures.WorkspaceEditClientCapabilities{
          document_changes: document_changes,
          resource_operations: resource_operations
        }
      }
    }
    |> Configuration.new(nil)
    |> Configuration.set()
  end

  defp unicode_range(document) do
    Document.Range.new(
      Document.Position.new(document, 2, 8),
      Document.Position.new(document, 2, 19)
    )
  end

  defp subject_uri(project, path) do
    project
    |> file_path(path)
    |> Document.Path.ensure_uri()
  end
end
