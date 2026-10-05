defmodule Expert.Project.SearchListenerTest do
  use ExUnit.Case
  use Patch
  use Expert.Test.DispatchFake

  import Expert.Test.Protocol.TransportSupport
  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Engine.Dispatch
  alias Expert.EngineApi
  alias Expert.Project.Diagnostics
  alias Expert.Project.EngineRuntime
  alias Expert.Project.Indexer
  alias Expert.Project.Reindex
  alias Expert.Project.SearchListener
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias GenLSP.Notifications.WindowShowMessage
  alias GenLSP.Structures.ShowMessageParams

  setup do
    project = project()
    test_pid = self()
    DispatchFake.start()
    start_supervised!({Expert.Project.Store, []})
    Expert.Project.Store.add_projects([project])
    patch(EngineRuntime, :mark_ready, fn ^project -> :ok end)

    patch(Expert.Project.Node, :trigger_build, fn ^project, force? ->
      send(test_pid, {:compile, force?})
    end)

    start_supervised!({Diagnostics, project})
    start_supervised!({Reindex, project})
    start_supervised!({SearchListener, project})
    {:ok, project: project}
  end

  describe "handling search_store_loading message" do
    setup [:with_patched_transport]

    test "shows window/showMessage notification", %{project: project} do
      EngineApi.broadcast(project, search_store_loading(project: project))

      expected_type = GenLSP.Enumerations.MessageType.info()
      expected_message = "Search index is loading for #{Project.name(project)}..."

      assert_receive {:transport,
                      %WindowShowMessage{
                        params: %ShowMessageParams{
                          type: ^expected_type,
                          message: ^expected_message
                        }
                      }}
    end
  end

  test "compilation success and failure request index refreshes", %{project: project} do
    test_pid = self()
    patch(Indexer, :refresh, fn ^project -> send(test_pid, :refresh) end)
    listener = SearchListener.name(project)

    send(listener, project_compiled(status: :success))
    assert_receive :refresh
    send(listener, project_compiled(status: :error))
    assert_receive :refresh
  end

  test "requests an incremental initial compile" do
    assert_receive {:compile, false}
  end

  test "registers permanent project listeners", %{project: project} do
    assert Dispatch.registered?(Process.whereis(Diagnostics.name(project)))
    assert Dispatch.registered?(Process.whereis(SearchListener.name(project)))
  end
end
