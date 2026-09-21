defmodule Expert.Project.IndexerTest do
  use ExUnit.Case, async: false
  use Patch
  use Expert.Test.DispatchFake

  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Indexer
  alias Expert.Project.Node, as: ProjectNode
  alias Expert.Search
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  # The first assertion after a broadcast waits on `Search.Store.enable/1`, which the store
  # allows 30 seconds for. Setup destroys the database first, so a cold rebuild can outlast the
  # global `assert_receive_timeout` of one second.
  @enable_timeout :timer.seconds(5)

  setup do
    project = project()
    DispatchFake.start()
    Sqlite.destroy_all(project)

    start_supervised!({Sqlite, [project, runtime_versions: runtime_versions()]})
    start_supervised!({Store, [project, Sqlite]})

    task_supervisor = :"#{Project.unique_name(project)}::indexer_test_task_supervisor"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    EngineApi.register_listener(project, self(), [project_index_ready()])

    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project, task_supervisor: task_supervisor}
  end

  describe "initial project compile" do
    test "forces compilation when the persisted index is empty", %{
      project: project,
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      patch(Store, :load_status, fn ^project -> :empty end)

      patch(ProjectNode, :trigger_build, fn ^project, force? ->
        send(test_pid, {:trigger_build, force?})
      end)

      start_supervised!(
        {Indexer, [project, task_supervisor: task_supervisor, initial_compile?: true]}
      )

      assert_receive {:trigger_build, true}
    end

    test "uses a normal compilation when a persisted index exists", %{
      project: project,
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      patch(Store, :load_status, fn ^project -> :stale end)

      patch(ProjectNode, :trigger_build, fn ^project, force? ->
        send(test_pid, {:trigger_build, force?})
      end)

      start_supervised!(
        {Indexer, [project, task_supervisor: task_supervisor, initial_compile?: true]}
      )

      assert_receive {:trigger_build, false}
    end
  end

  test "creates the initial index after a successful project compile", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    entry = definition(id: 1, subject: ProjectIndexer.Initial, path: "/initial.ex")

    patch(Search.Indexer, :commit_manifest, fn ^project, %Manifest{} ->
      send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.Initial, [])})
      :ok
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)

           {:ok, [entry], Manifest.new([])}
         end,
         update_index: fn ^project, _path_to_ids ->
           send(test_pid, :update_index)
           {:ok, [], [], Manifest.new([])}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive :create_index, @enable_timeout
    refute_receive :update_index

    assert_receive {:after_apply, {:ok, [^entry]}}
    assert_receive project_index_ready(project: ^project)
    assert_eventually {:ok, [^entry]} = Store.exact(project, ProjectIndexer.Initial, [])
  end

  test "creates the initial index even when the project compile reports an error", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    entry = definition(id: 1, subject: ProjectIndexer.OnError, path: "/on_error.ex")

    patch(Search.Indexer, :commit_manifest, fn ^project, %Manifest{} ->
      send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.OnError, [])})
      :ok
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)

           {:ok, [entry], Manifest.new([])}
         end,
         update_index: fn ^project, _path_to_ids ->
           send(test_pid, :update_index)
           {:ok, [], [], Manifest.new([])}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :error))

    assert_receive :create_index, @enable_timeout
    assert_receive {:after_apply, {:ok, [^entry]}}
    assert_receive project_index_ready(project: ^project)
    assert_eventually {:ok, [^entry]} = Store.exact(project, ProjectIndexer.OnError, [])
  end

  test "updates an existing index after later successful project compiles", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    path = "/stale.ex"
    old_entry = definition(id: 1, subject: ProjectIndexer.Stale, path: path)
    new_entry = definition(id: 2, subject: ProjectIndexer.Fresh, path: path)
    assert :ok = Store.replace(project, [old_entry])

    test_pid = self()

    patch(Search.Indexer, :commit_manifest, fn ^project, %Manifest{} ->
      send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.Fresh, [])})
      :ok
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)
           {:ok, [], Manifest.new([])}
         end,
         update_index: fn ^project, path_to_ids ->
           send(test_pid, {:update_index, path_to_ids})
           {:ok, [new_entry], [], Manifest.new([])}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive {:update_index, %{^path => 1}}, @enable_timeout
    refute_receive :create_index

    assert_receive {:after_apply, {:ok, [^new_entry]}}
    assert_receive project_index_ready(project: ^project)
    assert {:ok, []} = Store.exact(project, ProjectIndexer.Stale, [])
    assert {:ok, [^new_entry]} = Store.exact(project, ProjectIndexer.Fresh, [])
  end

  defp definition(opts) do
    opts = Keyword.validate!(opts, [:id, :subject, path: "/file.ex"])

    %Entry{
      id: Keyword.fetch!(opts, :id),
      subject: Keyword.fetch!(opts, :subject),
      path: Keyword.fetch!(opts, :path),
      type: :module,
      subtype: :definition,
      block_id: :root
    }
  end

  defp runtime_versions, do: %{erlang: "engine-erlang", elixir: "engine-elixir"}
end
