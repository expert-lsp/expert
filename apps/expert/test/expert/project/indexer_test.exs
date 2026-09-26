defmodule Expert.Project.IndexerTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Indexer
  alias Expert.Search
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite

  setup do
    project = project()
    Sqlite.destroy_all(project)

    start_supervised!(
      {Sqlite, [project, runtime_versions: %{erlang: "engine-erlang", elixir: "engine-elixir"}]}
    )

    start_supervised!({Store, [project, Sqlite]})
    start_supervised!({Search.Indexer.ModuleRegistry, project})
    start_supervised!({Task.Supervisor, name: Indexer.task_supervisor_name(project)})
    patch(EngineApi, :call, fn _, _, _, _ -> flunk("Index tasks must not control the Engine") end)
    test_pid = self()
    patch(EngineApi, :broadcast, fn ^project, message -> send(test_pid, message) end)
    patch(Search.Indexer, :warmup, fn _ -> :ok end)
    on_exit(fn -> Sqlite.destroy_all(project) end)
    {:ok, project: project}
  end

  test "creates an empty index on request", %{project: project} do
    test_pid = self()

    start_supervised!(
      {Indexer,
       [
         project,
         create_index: fn ^project ->
           send(test_pid, :create_index)
           :ok
         end,
         update_index: fn _ -> flunk("An empty index needs a full index") end
       ]}
    )

    Indexer.refresh(project)

    assert_receive :create_index, 5_000
    assert_receive project_index_ready(project: ^project)
  end

  test "updates an existing index on request", %{project: project} do
    test_pid = self()
    patch(Store, :load_status, fn ^project -> :ready end)

    start_supervised!(
      {Indexer,
       [
         project,
         create_index: fn _ -> flunk("An existing index needs an update") end,
         update_index: fn ^project ->
           send(test_pid, :update_index)
           :ok
         end
       ]}
    )

    Indexer.refresh(project)

    assert_receive :update_index, 5_000
    assert_receive project_index_ready(project: ^project)
  end

  test "rebuilds after an incremental Store write fails", %{project: project} do
    test_pid = self()
    patch(Store, :load_status, fn ^project -> :ready end)

    start_supervised!(
      {Indexer,
       [
         project,
         create_index: fn ^project ->
           send(test_pid, :create_index)
           :ok
         end,
         update_index: fn ^project ->
           send(test_pid, :update_index)
           {:error, {:store, :write_failed}}
         end
       ]}
    )

    Indexer.refresh(project)

    assert_receive :update_index, 5_000
    assert_receive :create_index
    assert_receive project_index_ready(project: ^project)
  end

  test "a refresh cancels unfinished warmup and keeps the project registry", %{project: project} do
    test_pid = self()

    patch(Search.Indexer, :warmup, fn ^project ->
      registry = Search.Indexer.ModuleRegistry.name(project)
      send(test_pid, {:warmup, self(), registry})
      Process.sleep(:infinity)
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         create_index: fn ^project ->
           send(test_pid, :create_index)
           :ok
         end
       ]}
    )

    assert_receive {:warmup, pid, registry}, 5_000
    ref = Process.monitor(pid)
    Indexer.refresh(project)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert_receive :create_index
    assert :ets.info(registry, :owner) == Process.whereis(registry)
    assert_receive project_index_ready(project: ^project)
  end

  test "completed warmup permits a later refresh", %{project: project} do
    test_pid = self()

    patch(Search.Indexer, :warmup, fn ^project ->
      send(test_pid, {:warmup, self()})
      :ok
    end)

    start_supervised!({Indexer, [project, create_index: fn _ -> :ok end]})
    assert_receive {:warmup, pid}, 5_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute_receive project_index_ready()

    Indexer.refresh(project)
    assert_receive project_index_ready(project: ^project)
  end

  test "failed warmup permits a later refresh", %{project: project} do
    test_pid = self()

    patch(Search.Indexer, :warmup, fn _ ->
      send(test_pid, {:warmup, self()})
      exit(:warmup_failed)
    end)

    start_supervised!({Indexer, [project, create_index: fn _ -> :ok end]})
    assert_receive {:warmup, pid}, 5_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    Indexer.refresh(project)
    assert_receive project_index_ready(project: ^project)
  end

  test "skips warmup when the store has a persisted index", %{project: project} do
    patch(Store, :load_status, :stale)
    patch(Search.Indexer, :warmup, fn _ -> flunk("A persisted index does not need warmup") end)
    start_supervised!({Indexer, project})
    assert_eventually(is_nil(:sys.get_state(Indexer.name(project)).task))
  end

  test "warmup stops when its owner is killed", %{project: project} do
    test_pid = self()

    patch(Search.Indexer, :warmup, fn _ ->
      send(test_pid, {:warmup, self()})
      Process.sleep(:infinity)
    end)

    owner = start_supervised!({Indexer, project})
    assert_receive {:warmup, worker}
    ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "coalesces refresh requests and reports readiness after the final refresh", %{
    project: project
  } do
    test_pid = self()

    start_supervised!(
      {Indexer,
       [
         project,
         create_index: fn _ ->
           send(test_pid, {:refresh, self()})

           receive do
             :finish -> :ok
           end
         end
       ]}
    )

    Indexer.refresh(project)
    assert_receive {:refresh, first}, 5_000
    Indexer.refresh(project)
    Indexer.refresh(project)
    :sys.get_state(Indexer.name(project))
    send(first, :finish)

    assert_receive {:refresh, second}
    refute_receive project_index_ready()
    send(second, :finish)
    assert_receive project_index_ready(project: ^project)
    refute_receive {:refresh, _}
  end
end
