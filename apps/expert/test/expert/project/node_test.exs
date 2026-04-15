defmodule Expert.Project.NodeTest do
  use ExUnit.Case
  use Forge.Test.EventualAssertions

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Node, as: EngineNode

  setup do
    project = project()

    {:ok, _} =
      start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

    {:ok, _} = start_supervised(Expert.EngineBuilds)
    {:ok, _} = start_supervised(Expert.ActiveProjects)
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    {:ok, _} = start_supervised({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    {:ok, _} = start_supervised({Expert.Project.Supervisor, project})

    :ok = EngineApi.register_listener(project, self(), [project_compiled()])

    {:ok, project: project}
  end

  test "the project should be compiled when the node starts" do
    assert_receive project_compiled(), :timer.seconds(15)
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

  defp node_pid(project) do
    project
    |> Expert.EngineNode.name()
    |> Process.whereis()
  end
end
