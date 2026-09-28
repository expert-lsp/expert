defmodule Engine.Commands.RenameTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions

  alias Engine.Api.Proxy
  alias Engine.Commands.Reindex
  alias Engine.Commands.Rename
  alias Engine.Commands.RenameSupervisor
  alias Engine.ManagerApi

  setup do
    start_supervised!(RenameSupervisor)
    :ok
  end

  setup do
    pid = self()

    on_report_progress = fn delta, message -> update_progress(pid, delta, message) end
    on_complete = fn -> complete_progress(pid) end

    patch(Proxy, :start_buffering, :ok)
    patch(Reindex, :uri, :ok)
    %{on_report_progress: on_report_progress, on_complete: on_complete}
  end

  test "it should start buffering when a rename is in progress", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    uri = "file://file.ex"
    uri_with_expected_operation = %{uri => file_changed(uri: uri)}
    paths_to_reindex = [uri]

    {:ok, _pid} =
      RenameSupervisor.start_renaming(
        uri_with_expected_operation,
        paths_to_reindex,
        [],
        on_report_progress,
        on_complete
      )

    assert_called(Proxy.start_buffering())
  end

  test "it should complete and shutdown the process when rename is done", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    uri = "file://file.ex"
    paths_to_reindex = [uri]

    {:ok, _pid} =
      RenameSupervisor.start_renaming(
        %{uri => file_saved(uri: uri)},
        paths_to_reindex,
        [],
        on_report_progress,
        on_complete
      )

    Rename.update_progress(file_saved(uri: uri))

    assert_receive {:update_progress, 1, ""}
    assert_receive :complete_progress

    refute_eventually Process.whereis(Rename)
  end

  test "it should still be in progress if there are files yet to be saved", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    uri1 = "file://file1.ex"
    old_uri = "file://file2.ex"
    new_uri = "file://file3.ex"

    uri_with_expected_operation = %{
      uri1 => file_changed(uri: uri1),
      new_uri => file_saved(uri: new_uri)
    }

    paths_to_reindex = [uri1, new_uri]
    paths_to_delete = [old_uri]

    {:ok, _pid} =
      RenameSupervisor.start_renaming(
        uri_with_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_report_progress,
        on_complete
      )

    Rename.update_progress(file_changed(uri: uri1))
    assert_receive {:update_progress, 1, ""}
    refute_receive :complete_progress
  end

  test "it should reindex new files and delete old entries when all files are modified", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    patch(ManagerApi, :search_store_clear, :ok)
    old_uri = "file://old_file.ex"
    new_uri = "file://new_file.ex"
    another_uri = "file://file.ex"

    uri_with_expected_operation = %{
      old_uri => file_changed(uri: old_uri),
      new_uri => file_saved(uri: new_uri)
    }

    paths_to_reindex = [new_uri, another_uri]
    paths_to_delete = [old_uri]

    {:ok, _pid} =
      RenameSupervisor.start_renaming(
        uri_with_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_report_progress,
        on_complete
      )

    Rename.update_progress(file_changed(uri: old_uri))
    assert_receive {:update_progress, 1, ""}
    refute_receive :complete_progress

    Rename.update_progress(file_saved(uri: new_uri))
    assert_receive {:update_progress, 1, ""}

    assert_receive {:update_progress, 1, "reindexing"}
    assert_receive {:update_progress, 1, "deleting old index"}
    assert_receive :complete_progress
  end

  test "it should return :error when updating progress if no rename is in progress" do
    assert {:error, :not_in_rename_progress} =
             Rename.update_progress(file_changed(uri: "file://file.ex"))
  end

  test "it should complete and shutdown when notifications time out", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    uri = "file://file.ex"

    {:ok, pid} =
      RenameSupervisor.start_renaming(
        %{uri => file_saved(uri: uri)},
        [uri],
        [],
        on_report_progress,
        on_complete
      )

    send(pid, :timeout)

    assert_receive :complete_progress
    refute_eventually Process.whereis(Rename)
    refute_called(Reindex.uri(_))
  end

  test "it should accept file_changed when file_saved is expected", %{
    on_report_progress: on_report_progress,
    on_complete: on_complete
  } do
    uri = "file://file.ex"

    {:ok, _pid} =
      RenameSupervisor.start_renaming(
        %{uri => file_saved(uri: uri)},
        [],
        [],
        on_report_progress,
        on_complete
      )

    Rename.update_progress(file_changed(uri: uri))

    assert_receive :complete_progress
  end

  defp update_progress(pid, delta, message) do
    send(pid, {:update_progress, delta, message})
  end

  defp complete_progress(pid) do
    send(pid, :complete_progress)
  end
end
