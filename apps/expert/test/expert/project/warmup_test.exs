defmodule Expert.Project.WarmupTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.EventualAssertions

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.Progress
  alias Expert.Project.Indexer
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Document
  alias Forge.Project

  @tag :tmp_dir
  test "source symbols become available while the Engine starts", %{tmp_dir: root} do
    File.write!(Path.join(root, "example.ex"), "defmodule WarmupExample, do: def(run, do: :ok)")
    project = root |> Document.Path.to_uri() |> Project.bare()

    start_supervised!({Sqlite, [project, runtime_versions: Forge.VM.Versions.current()]})
    start_supervised!({Store, [project, Sqlite]})
    start_supervised!({Expert.Search.Indexer.ModuleRegistry, project})
    start_supervised!({Task.Supervisor, name: Indexer.task_supervisor_name(project)})
    start_supervised!({Expert.Project.Store, []})
    patch(EngineApi, :call, fn _, _, _, _ -> flunk("Warmup must work without the Engine") end)
    patch(Progress, :begin, fn _, _ -> {:error, :rejected} end)

    patch(Progress, :with_progress, fn _, fun ->
      {:done, result, _message} = fun.(Progress.noop_token())
      result
    end)

    test_pid = self()

    patch(EngineNode, :start, fn ^project, _token ->
      send(test_pid, {:engine_start, self()})

      receive do
        :finish -> {:error, :test_stop}
      end
    end)

    start_supervised!({Indexer, project})

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Expert.Project.Node.start_link(project)
      end)

    assert_receive {:engine_start, node_pid}

    assert_eventually(
      match?({:ok, [_ | _]}, Store.exact(project, "WarmupExample.run/0", subtype: :definition)),
      5_000
    )

    send(node_pid, :finish)
    assert {:error, _} = Task.await(task)
  end
end
