defmodule Expert.Project.SupervisorTest do
  use ExUnit.Case, async: false
  use Forge.Test.EventualAssertions
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Configuration
  alias Expert.EngineNode
  alias Expert.Project.EngineRuntime
  alias Expert.Project.Indexer
  alias Expert.Project.MixProject
  alias Expert.Project.Node
  alias Expert.Project.Reindex
  alias Expert.Project.Store, as: ProjectStore
  alias Expert.Project.Supervisor, as: ProjectSupervisor
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite

  setup do
    project = project()
    Sqlite.destroy_all(project)
    Configuration.new() |> Configuration.set()

    start_supervised!({ProjectStore, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    ProjectStore.add_projects([project])

    on_exit(fn ->
      :persistent_term.erase(Configuration)
      Sqlite.destroy_all(project)
    end)

    {:ok, project: project}
  end

  test "starts manager indexing without the Engine when compilation is disabled", %{
    project: project
  } do
    test_pid = self()
    versions = %{erlang: "project-erlang", elixir: "project-elixir"}
    patch(MixProject, :runtime_versions, fn ^project -> {:ok, versions} end)

    patch(Expert.Search.Indexer, :warmup, fn ^project ->
      send(test_pid, :warmup)
      :ok
    end)

    {:ok, _config} = Configuration.on_change(%{"enableCompilation" => false})

    assert {:ok, _pid} = ProjectSupervisor.ensure_node_started(project)

    assert is_pid(Process.whereis(Store.name(project)))
    assert is_pid(Process.whereis(Indexer.name(project)))
    assert is_pid(Process.whereis(Reindex.name(project)))

    assert :sys.get_state(Sqlite.name(project)).database_path ==
             Sqlite.database_path(project, versions)

    refute ProjectStore.ready?(project)
    assert Process.whereis(Node.name(project)) == nil
    refute EngineRuntime.available?(project)
    assert_receive :warmup
    refute_receive :warmup
  end

  test "a disabled compilation setting blocks access to an initialized Engine", %{
    project: project
  } do
    name = EngineNode.name(project)

    start_supervised!(%{
      id: name,
      start: {Agent, :start_link, [fn -> :ok end, [name: name]]}
    })

    assert ProjectStore.transition(project, :ready)
    assert EngineRuntime.available?(project)

    {:ok, _config} = Configuration.on_change(%{"enableCompilation" => false})
    refute EngineRuntime.available?(project)
  end

  test "disabling compilation starts indexing for a blocked project", %{project: project} do
    test_pid = self()

    patch(Indexer, :refresh, fn ^project ->
      send(test_pid, :refresh)
      :ok
    end)

    assert ProjectStore.transition(project, :blocked)
    {:ok, _config} = Configuration.on_change(%{"enableCompilation" => false})

    assert :ok = ProjectSupervisor.stop_engine(project)
    assert is_pid(Process.whereis(Indexer.name(project)))
    refute ProjectStore.blocked?(project)
    refute EngineRuntime.available?(project)
    assert_receive :refresh
  end

  test "keeps manager indexing alive when Engine startup fails", %{project: project} do
    test_pid = self()

    patch(EngineRuntime, :start_link, fn ^project ->
      send(test_pid, :engine_start)
      {:error, :engine_failed}
    end)

    assert {:ok, _pid} = ProjectSupervisor.ensure_node_started(project)
    assert_receive :engine_start
    refute_receive :engine_start

    assert is_pid(Process.whereis(ProjectSupervisor.name(project)))
    assert is_pid(Process.whereis(Store.name(project)))
    assert is_pid(Process.whereis(Indexer.name(project)))
    assert is_pid(Process.whereis(Reindex.name(project)))
    refute ProjectStore.ready?(project)
    refute EngineRuntime.available?(project)
  end

  test "a blocked project does not start the Engine", %{project: project} do
    {:ok, _config} = Configuration.on_change(%{"enableCompilation" => false})
    assert {:ok, _supervisor} = ProjectSupervisor.ensure_node_started(project)
    assert ProjectStore.transition(project, :blocked)

    patch(EngineRuntime, :start_link, fn ^project -> flunk("A blocked project cannot start") end)

    {:ok, _config} = Configuration.on_change(%{"enableCompilation" => true})
    assert :ok = ProjectSupervisor.start_engine(project)

    assert engine_children(project) == []
  end

  test "a restarted manager restores the Engine runtime", %{project: project} do
    patch(EngineRuntime, :start_link, fn ^project ->
      Agent.start_link(fn -> :ok end, name: EngineRuntime.name(project))
    end)

    assert {:ok, supervisor} = ProjectSupervisor.ensure_node_started(project)

    Process.exit(supervisor, :kill)

    assert_eventually(
      case {Process.whereis(ProjectSupervisor.name(project)),
            Process.whereis(EngineRuntime.name(project))} do
        {pid, runtime} when is_pid(pid) and pid != supervisor and is_pid(runtime) ->
          true

        _ ->
          false
      end,
      1_000
    )
  end

  defp engine_children(project) do
    project
    |> ProjectSupervisor.name()
    |> Supervisor.which_children()
    |> Enum.filter(&match?({EngineRuntime, _, _, _}, &1))
  end
end
