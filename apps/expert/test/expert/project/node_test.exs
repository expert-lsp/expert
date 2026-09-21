defmodule Expert.Project.NodeTest do
  use ExUnit.Case
  use Forge.Test.EventualAssertions
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Indexer
  alias Expert.Project.Node, as: EngineNode

  setup do
    project = project()

    {:ok, _} =
      start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

    {:ok, _} = start_supervised(Expert.EngineBuilds)
    {:ok, _} = start_supervised({Expert.Project.Store, []})
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    {:ok, _} = start_supervised({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    {:ok, _} = start_supervised({Expert.Project.Supervisor, project})

    :ok = EngineApi.register_listener(project, self(), [project_compiled()])

    {:ok, project: project}
  end

  test "the project should be compiled when the node starts" do
    assert_receive project_compiled(), :timer.seconds(15)
  end

  test "trigger_build forwards the requested compile mode", %{project: project} do
    test_pid = self()

    patch(EngineApi, :schedule_compile, fn ^project, force? ->
      send(test_pid, {:schedule_compile, force?})
    end)

    EngineNode.trigger_build(project, false)

    assert_receive {:schedule_compile, false}
  end

  test "remote control is started when the node starts", %{project: project} do
    apps = EngineApi.call(project, Application, :started_applications)
    app_names = Enum.map(apps, &elem(&1, 0))
    assert :engine in app_names
  end

  test "the node is restarted when it goes down", %{project: project} do
    node_name = EngineNode.node_name(project)
    old_pid = node_pid(project)

    :ok = EngineApi.stop(project)
    assert_eventually(Node.ping(node_name) == :pong, 7000)

    new_pid = node_pid(project)
    assert is_pid(new_pid)
    assert new_pid != old_pid
  end

  test "the node restarts when the supervisor pid is killed", %{project: project} do
    node_name = EngineNode.node_name(project)
    supervisor_pid = EngineApi.call(project, Process, :whereis, [Engine.Supervisor])

    assert is_pid(supervisor_pid)
    Process.exit(supervisor_pid, :kill)
    assert_eventually(Node.ping(node_name) == :pong, 750)
  end

  test "a supervised Node restart registers before its compile request", %{project: project} do
    test_pid = self()

    patch(EngineApi, :register_listener, fn ^project, listener, messages ->
      send(test_pid, {:registered, listener, messages})
      :ok
    end)

    patch(EngineApi, :schedule_compile, fn ^project, force? ->
      send(test_pid, {:compile, force?})
      :ok
    end)

    old_pid = Process.whereis(EngineNode.name(project))
    Process.exit(old_pid, :kill)

    assert_eventually(
      case Process.whereis(EngineNode.name(project)) do
        pid when is_pid(pid) -> pid != old_pid
        _ -> false
      end,
      :timer.seconds(15)
    )

    assert_receive {:registered, new_pid, [project_compiled() | _]}, :timer.seconds(15)
    assert new_pid == Process.whereis(Indexer.name(project))
    assert_receive {:compile, _force?}, :timer.seconds(15)
    refute_receive {:compile, _}
  end

  defp node_pid(project) do
    project
    |> Expert.EngineNode.name()
    |> Process.whereis()
  end
end
