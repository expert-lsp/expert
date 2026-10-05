defmodule Expert.Project.NodeTest do
  use ExUnit.Case, async: false
  use Forge.Test.EventualAssertions
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project.Diagnostics
  alias Expert.Project.EngineRuntime
  alias Expert.Project.Node, as: EngineNode
  alias Expert.Project.Reindex
  alias Expert.Project.SearchListener

  setup do
    project = project()
    Configuration.new() |> Configuration.set()

    on_exit(fn -> :persistent_term.erase(Configuration) end)

    {:ok, _} =
      start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

    {:ok, _} = start_supervised(Expert.EngineBuilds)
    {:ok, _} = start_supervised({Expert.Project.Store, []})
    Expert.Project.Store.add_projects([project])
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    {:ok, _} = start_supervised({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    assert {:ok, _pid} = Expert.Project.Supervisor.ensure_node_started(project)

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
    assert new_pid == Process.whereis(SearchListener.name(project))
    assert_receive {:compile, _force?}, :timer.seconds(15)
    refute_receive {:compile, _}
    assert EngineRuntime.available?(project)
  end

  test "an Indexer restart leaves the Engine running", %{project: project} do
    runtime = Process.whereis(EngineRuntime.name(project))
    node = node_pid(project)
    indexer = Process.whereis(Expert.Project.Indexer.name(project))
    reindex = Process.whereis(Reindex.name(project))

    Process.exit(indexer, :kill)

    assert_eventually(Process.whereis(Expert.Project.Indexer.name(project)) != indexer)
    assert Process.whereis(EngineRuntime.name(project)) == runtime
    assert node_pid(project) == node
    assert Process.whereis(Reindex.name(project)) == reindex
    assert EngineRuntime.available?(project)
  end

  test "concurrent Engine starts create one runtime", %{project: project} do
    assert :ok = Expert.Project.Supervisor.stop_engine(project)

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> Expert.Project.Supervisor.start_engine(project) end)
      end

    assert [:ok, :ok] = Task.await_many(tasks, 15_000)

    assert is_pid(Process.whereis(EngineRuntime.name(project)))
  end

  test "an Engine runtime restart clears readiness until startup finishes", %{project: project} do
    test_pid = self()

    patch(SearchListener, :start_link, fn ^project ->
      send(test_pid, {:search_listener_starting, self()})

      receive do
        :continue -> real(SearchListener).start_link(project)
      end
    end)

    runtime = Process.whereis(EngineRuntime.name(project))
    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)

    assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}
    assert_receive {:search_listener_starting, starter}, 15_000
    refute EngineRuntime.available?(project)

    send(starter, :continue)
    assert_eventually(Process.whereis(EngineRuntime.name(project)) != runtime, 15_000)
    assert_eventually(EngineRuntime.available?(project), 15_000)
  end

  test "a Diagnostics restart restores its Engine registration", %{project: project} do
    test_pid = self()

    patch(EngineApi, :register_listener, fn ^project, listener, messages ->
      send(test_pid, {:registered, listener, messages})
      :ok
    end)

    diagnostics = Process.whereis(Diagnostics.name(project))
    Process.exit(diagnostics, :kill)

    assert_eventually(Process.whereis(Diagnostics.name(project)) != diagnostics)

    assert_receive {:registered, listener,
                    [
                      file_diagnostics(),
                      project_compile_requested(),
                      project_compiled(),
                      project_diagnostics()
                    ]}

    assert listener == Process.whereis(Diagnostics.name(project))
  end

  test "hot toggles preserve manager index processes", %{project: project} do
    manager_processes = fn ->
      {
        Process.whereis(Expert.Search.Store.name(project)),
        Process.whereis(Expert.Project.Indexer.name(project)),
        Process.whereis(Diagnostics.name(project))
      }
    end

    processes = manager_processes.()

    assert EngineRuntime.available?(project)

    {:ok, _config} = Expert.Configuration.on_change(%{"enableCompilation" => false})
    assert :ok = Expert.Project.Supervisor.stop_engine(project)

    assert Process.whereis(EngineNode.name(project)) == nil
    assert manager_processes.() == processes
    refute EngineRuntime.available?(project)

    {:ok, _config} = Expert.Configuration.on_change(%{"enableCompilation" => true})
    assert :ok = Expert.Project.Supervisor.start_engine(project)

    assert is_pid(Process.whereis(EngineNode.name(project)))
    assert manager_processes.() == processes
    assert EngineRuntime.available?(project)

    runtime = Process.whereis(EngineRuntime.name(project))
    assert :ok = Expert.Project.Supervisor.start_engine(project)
    assert Process.whereis(EngineRuntime.name(project)) == runtime
  end

  defp node_pid(project) do
    project
    |> Expert.EngineNode.name()
    |> Process.whereis()
  end
end
