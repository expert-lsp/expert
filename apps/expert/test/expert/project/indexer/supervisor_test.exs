defmodule Expert.Project.Indexer.SupervisorTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Project.Indexer
  alias Expert.Search
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite

  test "stops an index task when the indexer restarts" do
    project = project()
    test_pid = self()
    Sqlite.destroy_all(project)
    on_exit(fn -> Sqlite.destroy_all(project) end)

    start_supervised!(
      {Sqlite, [project, runtime_versions: %{erlang: "engine-erlang", elixir: "engine-elixir"}]}
    )

    start_supervised!({Store, [project, Sqlite]})
    start_supervised!({Search.Indexer.ModuleRegistry, project})

    patch(Search.Indexer, :warmup, fn ^project ->
      send(test_pid, {:warmup, self()})
      Process.sleep(:infinity)
    end)

    start_supervised!({Indexer.Supervisor, project})
    assert_receive {:warmup, first_task}, 5_000
    first_task_ref = Process.monitor(first_task)

    project
    |> Indexer.name()
    |> Process.whereis()
    |> Process.exit(:kill)

    assert_receive {:DOWN, ^first_task_ref, :process, ^first_task, _reason}, 5_000
    assert_receive {:warmup, second_task}, 5_000
    assert second_task != first_task
  end
end
