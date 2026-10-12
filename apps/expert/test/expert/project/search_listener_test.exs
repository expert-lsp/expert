defmodule Expert.Project.SearchListenerTest do
  use ExUnit.Case
  use Patch
  use Expert.Test.DispatchFake

  import Expert.Test.Protocol.TransportSupport
  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Indexer
  alias Expert.Project.SearchListener
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias GenLSP.Notifications.WindowShowMessage
  alias GenLSP.Structures.ShowMessageParams

  setup do
    project = project()
    test_pid = self()
    Process.register(self(), Indexer.name(project))
    DispatchFake.start()

    patch(Expert.Project.Node, :trigger_build, fn ^project, force? ->
      send(test_pid, {:compile, force?})
    end)

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

  test "registers the indexer for compilation events", %{project: project} do
    EngineApi.broadcast(project, project_compiled(status: :success))

    assert_receive project_compiled(status: :success)
  end

  test "requests an incremental initial compile" do
    assert_receive {:compile, false}
  end
end
