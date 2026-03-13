defmodule Expert.EngineNodeTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineNode
  alias Expert.EngineSupervisor

  setup do
    project = project()
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!(Expert.ActiveProjects)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!({EngineSupervisor, project})
    {:ok, %{project: project}}
  end

  test "it should be able to stop a project node and won't restart", %{project: project} do
    assert {:ok, _node_name, _} = try_start(project)

    project_alive? = project |> EngineNode.name() |> Process.whereis() |> Process.alive?()

    assert project_alive?
    assert :ok = EngineNode.stop(project, 1500)
    assert_eventually(Process.whereis(EngineNode.name(project)) == nil, :timer.seconds(5))
  end

  test "it should be stopped atomically when the startup process is dead", %{project: project} do
    test_pid = self()

    linked_node_process =
      spawn(fn ->
        case try_start(project) do
          {:ok, _node_name, _} -> send(test_pid, :started)
          {:error, reason} -> send(test_pid, {:error, reason})
        end
      end)

    assert_receive :started, 20_000

    node_process_name = EngineNode.name(project)

    assert node_process_name |> Process.whereis() |> Process.alive?()
    Process.exit(linked_node_process, :kill)
    assert_eventually(Process.whereis(node_process_name) == nil, 100)
  end

  test "terminates the server if no elixir is found", %{project: project} do
    test_pid = self()

    patch(Expert.Port, :open_elixir, {:error, :no_elixir, "elixir not found"})

    patch(Expert, :terminate, fn _, status ->
      send(test_pid, {:stopped, status})
    end)

    # Note(dorgan): ideally we would use GenLSP.Test here, but
    # calling `server(Expert)` causes the tests to behave erratically
    # and either not run or terminate ExUnit early
    patch(GenLSP, :error, fn _, message ->
      send(test_pid, {:lsp_log, message})
    end)

    assert {:error, :no_elixir} = EngineNode.start(project)
  end

  test "shuts down with error message if exited with error code", %{project: project} do
    {:ok, _node_name, node_pid} = EngineNode.start(project)

    Process.monitor(node_pid)

    exit_status = 127

    send(node_pid, {nil, {:exit_status, exit_status}})

    assert_receive {:DOWN, _ref, :process, ^node_pid, exit_reason}

    assert {:shutdown, {:node_exit, node_exit}} = exit_reason
    assert %{status: ^exit_status, last_message: last_message} = node_exit
    assert is_binary(last_message)
  end

  test "detect_deps_error recognizes Mix dependency errors" do
    assert EngineNode.State.detect_deps_error(
             "** (Mix) Can't continue due to errors on dependencies"
           )

    assert EngineNode.State.detect_deps_error(
             "** (Mix.Error) Can't continue due to errors on dependencies"
           )

    assert EngineNode.State.detect_deps_error("Unchecked dependencies for dependency_foo")
    refute EngineNode.State.detect_deps_error("Compiling 1 file (.ex)")
    refute EngineNode.State.detect_deps_error("")
  end

  defp try_start(project, retries \\ 2) do
    case EngineNode.start(project) do
      {:ok, _, _} = ok ->
        ok

      {:error, _} when retries > 0 ->
        Process.sleep(200)
        try_start(project, retries - 1)

      {:badrpc, :nodedown} when retries > 0 ->
        Process.sleep(200)
        try_start(project, retries - 1)

      other ->
        other
    end
  end
end
