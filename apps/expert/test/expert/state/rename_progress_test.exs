defmodule Expert.State.RenameProgressTest do
  @moduledoc """
  Integration tests for rename progress tracking with different editors.

  Different editors send different events after rename operations:
  - VSCode: sends both file_changed and file_saved events for renamed files
  - Neovim: sends only file_changed for non-renamed files, file_saved for renamed files

  These tests verify the full rename flow from State → EngineApi → Engine.
  """

  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Engine.Commands.Rename
  alias Engine.Commands.RenameSupervisor
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project.Store
  alias Expert.State
  alias Forge.Document

  setup do
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Store, []})
    start_supervised!(RenameSupervisor)

    patch(Engine.Api.Proxy, :start_buffering, :ok)
    patch(Engine.Commands.Reindex, :uri, fn _uri -> :ok end)
    patch(Engine.ManagerApi, :search_store_clear, fn _project, _path -> :ok end)

    if pid = Process.whereis(Rename) do
      Process.exit(pid, :kill)
      Process.sleep(10)
    end

    :ok
  end

  describe "VSCode editor - non-file-rename (edits only)" do
    test "reindex triggers after file_changed" do
      editor = vscode_editor()
      uri = subject_uri(editor.project, "lib/foo.ex")
      open_document(uri, "defmodule Foo do\nend")
      expect_events_before_reindex(%{uri => file_saved(uri: uri)}, reindex: [uri])

      simulate_did_change(editor, uri)
      assert_reindex_triggered(reindex: [uri], delete: [])
    end
  end

  describe "race condition - didClose before didSave" do
    test "rename progress is updated even when file is already closed" do
      # This can happen during batch renames when didClose and didSave
      # arrive nearly simultaneously and didClose is processed first
      editor = vscode_editor()
      uri = subject_uri(editor.project, "lib/race.ex")
      open_document(uri, "defmodule Race do\nend")
      expect_events_before_reindex(%{uri => file_saved(uri: uri)}, reindex: [uri])

      # Simulate didClose being processed before didSave
      :ok = Document.Store.close(uri)

      # didSave should still succeed and update rename progress
      simulate_did_save(editor, uri)
      assert_reindex_triggered(reindex: [uri], delete: [])
    end
  end

  describe "Neovim editor - non-file-rename (edits only)" do
    test "reindex triggers after file_changed only (Neovim doesn't auto-save)" do
      editor = neovim_editor()
      uri = subject_uri(editor.project, "lib/foo.ex")
      open_document(uri, "defmodule Foo do\nend")
      expect_events_before_reindex(%{uri => file_changed(uri: uri)}, reindex: [uri])

      simulate_did_change(editor, uri)

      assert_reindex_triggered(reindex: [uri], delete: [])
    end
  end

  describe "VSCode editor - file rename" do
    test "reindex triggers after receiving file_changed for old + file_saved for new" do
      editor = vscode_editor()
      old_uri = subject_uri(editor.project, "lib/old_module.ex")
      new_uri = subject_uri(editor.project, "lib/new_module.ex")

      open_document(old_uri, "defmodule OldModule do\nend")
      open_document(new_uri, "defmodule NewModule do\nend")

      expect_events_before_reindex(
        %{new_uri => file_saved(uri: new_uri)},
        reindex: [new_uri],
        delete: [old_uri]
      )

      simulate_did_change(editor, old_uri)
      refute_reindex_triggered()

      simulate_did_save(editor, new_uri)
      assert_reindex_triggered(reindex: [new_uri], delete: [old_uri])
    end
  end

  describe "Neovim editor - file rename" do
    test "reindex triggers after file_saved for new file only" do
      editor = neovim_editor()
      old_uri = subject_uri(editor.project, "lib/old_neovim.ex")
      new_uri = subject_uri(editor.project, "lib/new_neovim.ex")

      open_document(new_uri, "defmodule NewNeovim do\nend")

      expect_events_before_reindex(
        %{new_uri => file_saved(uri: new_uri)},
        reindex: [new_uri],
        delete: [old_uri]
      )

      simulate_did_save(editor, new_uri)

      assert_reindex_triggered(reindex: [new_uri], delete: [old_uri])
    end
  end

  # ============================================================================
  # Test DSL - Editor simulation
  # ============================================================================

  defp vscode_editor do
    build_editor("Visual Studio Code")
  end

  defp neovim_editor do
    build_editor("Neovim")
  end

  defp build_editor(client_name) do
    project = project()
    project |> List.wrap() |> Store.set_projects()
    Store.transition(project, :ready)
    [client_name: client_name] |> Configuration.new() |> Configuration.set()
    state = %State{initialized?: true}

    patch(EngineApi, :broadcast, fn ^project, _msg -> :ok end)
    patch(EngineApi, :compile_document, fn ^project, _doc -> :ok end)
    patch(EngineApi, :schedule_compile, fn ^project, _ -> :ok end)

    patch(EngineApi, :maybe_update_rename_progress, fn ^project, msg ->
      Rename.update_progress(msg)
    end)

    %{state: state, version: 1, project: project}
  end

  defp subject_uri(project, path) do
    project
    |> file_path(path)
    |> Document.Path.ensure_uri()
  end

  defp open_document(uri, content) do
    :ok = Document.Store.open(uri, content, 1)
  end

  defp simulate_did_change(editor, uri) do
    new_version = editor.version + 1
    notification = build_did_change(uri, new_version)
    {:ok, new_state} = State.apply(editor.state, notification)
    %{editor | state: new_state, version: new_version}
  end

  defp simulate_did_save(editor, uri) do
    notification = build_did_save(uri)
    {:ok, new_state} = State.apply(editor.state, notification)
    %{editor | state: new_state}
  end

  # ============================================================================
  # Test DSL - Expectations
  # ============================================================================

  defp expect_events_before_reindex(uri_to_expected, opts) do
    paths_to_reindex = Keyword.get(opts, :reindex, [])
    paths_to_delete = Keyword.get(opts, :delete, [])
    test_pid = self()

    on_complete = fn ->
      send(test_pid, {:rename_complete, paths_to_reindex, paths_to_delete})
    end

    {:ok, _} =
      RenameSupervisor.start_renaming(
        uri_to_expected,
        paths_to_reindex,
        paths_to_delete,
        fn _delta, _msg -> :ok end,
        on_complete
      )
  end

  defp assert_reindex_triggered(opts) do
    reindex = Keyword.fetch!(opts, :reindex)
    delete = Keyword.fetch!(opts, :delete)
    assert_receive {:rename_complete, ^reindex, ^delete}
  end

  defp refute_reindex_triggered do
    refute_receive {:rename_complete, _, _}, 50
  end

  # ============================================================================
  # LSP notification builders
  # ============================================================================

  defp build_did_change(uri, version) do
    %GenLSP.Notifications.TextDocumentDidChange{
      params: %GenLSP.Structures.DidChangeTextDocumentParams{
        text_document: %GenLSP.Structures.VersionedTextDocumentIdentifier{
          uri: uri,
          version: version
        },
        content_changes: [%{text: "defmodule Renamed do\nend"}]
      }
    }
  end

  defp build_did_save(uri) do
    %GenLSP.Notifications.TextDocumentDidSave{
      params: %GenLSP.Structures.DidSaveTextDocumentParams{
        text_document: %GenLSP.Structures.TextDocumentIdentifier{uri: uri}
      }
    }
  end
end
