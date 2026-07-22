defmodule Expert.EngineNodeTest do
  use ExUnit.Case, async: false
  use Patch

  import ExUnit.CaptureLog
  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Forge.Document
  alias Forge.Project

  setup do
    project = project()
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Expert.Project.Store, []})
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

  test "replies to a pending stopper when the monitored process dies", %{project: project} do
    reply_ref = make_ref()

    state = %{
      EngineNode.State.new(project)
      | status: :stopping,
        stopped_by: {self(), reply_ref}
    }

    patch(EngineNode.State, :on_monitored_dead, fn _state -> state end)

    assert {:stop, :shutdown, ^state} =
             EngineNode.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert_receive {^reply_ref, :ok}
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

  @tag :tmp_dir
  test "cleans up state after an invalid Mix project load", %{tmp_dir: tmp_dir} do
    source = """
      defmodule Broken.BootstrapHelper do
        def loop(parent) do
          Process.register(self(), :broken_bootstrap_loop)
          send(parent, :broken_bootstrap_loop_started)

          receive do
            :stop -> :ok
          end
        end
      end

      defmodule Broken.MixProject do
        use Mix.Project
        parent = self()
        spawn(fn -> Broken.BootstrapHelper.loop(parent) end)
        receive do: (:broken_bootstrap_loop_started -> :ok)
        Code.put_compiler_option(:ignore_module_conflict, true)
        Mix.target(:rejected_target)
        Enum.test()
        def project, do: [app: :broken, version: "0.1.0"]
      end
    """

    {project, log} = start_invalid_project(tmp_dir, source)
    refute log =~ "raised an exception"
    refute EngineApi.call(project, Code, :ensure_loaded?, [Broken.BootstrapHelper])
    refute EngineApi.call(project, Process, :whereis, [:broken_bootstrap_loop])
    refute EngineApi.call(project, Code, :get_compiler_option, [:ignore_module_conflict])
    assert EngineApi.call(project, Mix, :target) == :host

    diagnostics = initial_project_diagnostics(project)
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "Enum.test/0"))
  end

  @tag :tmp_dir
  test "reports an exception after bootstrap warnings", %{tmp_dir: tmp_dir} do
    source = """
    defmodule WarningBootstrapHelper do
      defp unused, do: :warning
    end

    raise "bootstrap boom"
    """

    {project, _log} = start_invalid_project(tmp_dir, source)
    diagnostics = initial_project_diagnostics(project)

    assert %{position: position} =
             Enum.find(diagnostics, &(&1.severity == :warning and &1.message =~ "unused"))

    refute position == 1
    assert Enum.any?(diagnostics, &(&1.severity == :error and &1.message =~ "bootstrap boom"))
  end

  @tag :tmp_dir
  test "reports when mix.exs does not define a Mix project", %{tmp_dir: tmp_dir} do
    source = """
    defmodule OnlyBootstrapHelper do
    end
    """

    {project, _log} = start_invalid_project(tmp_dir, source)
    diagnostics = initial_project_diagnostics(project)

    assert Enum.any?(diagnostics, &(&1.severity == :error and &1.message =~ "does not define"))
    refute EngineApi.call(project, Code, :ensure_loaded?, [OnlyBootstrapHelper])
  end

  @tag :tmp_dir
  test "reports a bootstrap exit without a stacktrace", %{tmp_dir: tmp_dir} do
    {project, _log} = start_invalid_project(tmp_dir, "exit(1)")

    assert [diagnostic] = initial_project_diagnostics(project)
    assert diagnostic.message == "mix.exs compilation exited: 1"
    assert diagnostic.severity == :error
    assert diagnostic.uri == Document.Path.to_uri(Path.join(tmp_dir, "mix.exs"))
  end

  @tag :tmp_dir
  test "reports a bootstrap throw without a stacktrace", %{tmp_dir: tmp_dir} do
    {project, _log} = start_invalid_project(tmp_dir, "throw(:bootstrap_failure)")

    assert [diagnostic] = initial_project_diagnostics(project)
    assert diagnostic.message == "mix.exs compilation threw: :bootstrap_failure"
  end

  @tag :tmp_dir
  test "cleans up modules when the bootstrap compiler is killed", %{tmp_dir: tmp_dir} do
    source = "defmodule KilledBootstrapHelper do\nend\nProcess.exit(self(), :kill)"
    {project, _log} = start_invalid_project(tmp_dir, source)

    assert [diagnostic] = initial_project_diagnostics(project)
    assert diagnostic.message == "mix.exs compilation exited: :killed"
    refute EngineApi.call(project, Code, :ensure_loaded?, [KilledBootstrapHelper])
  end

  test "passes isolated engine tooling env when starting project node", %{project: project} do
    test_pid = self()

    tooling_env = [
      {"MIX_INSTALL_DIR", "/isolated/mix_install"},
      {"MIX_HOME", "/isolated/mix_home"},
      {"MIX_ARCHIVES", "/isolated/mix_archives"},
      {"REBAR_CACHE_DIR", "/isolated/rebar_cache"}
    ]

    patch(Forge.EPMD, :dist_port, fn -> 13_737 end)

    patch(Expert.Port, :open_elixir, fn _project, opts ->
      send(test_pid, {:open_elixir_opts, opts})
      make_ref()
    end)

    state = EngineNode.State.new(project)

    assert {:ok, _state} =
             EngineNode.State.start(state, [], {self(), make_ref()}, tooling_env: tooling_env)

    assert_receive {:open_elixir_opts, opts}, 1_000

    env = Keyword.fetch!(opts, :env)

    assert {"MIX_INSTALL_DIR", "/isolated/mix_install"} in env
    assert {"MIX_HOME", "/isolated/mix_home"} in env
    assert {"MIX_ARCHIVES", "/isolated/mix_archives"} in env
    assert {"REBAR_CACHE_DIR", "/isolated/rebar_cache"} in env
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
    assert EngineNode.State.detect_deps_error("** (Mix.Error) Hex dependency resolution failed")
    refute EngineNode.State.detect_deps_error("Compiling 1 file (.ex)")
    refute EngineNode.State.detect_deps_error("")
  end

  defp start_invalid_project(tmp_dir, source) do
    File.write!(Path.join(tmp_dir, "mix.exs"), source)
    project = tmp_dir |> Document.Path.to_uri() |> Project.new()
    start_supervised!({EngineSupervisor, project})

    assert {{:ok, _node_name, _node_pid}, log} = with_log(fn -> EngineNode.start(project) end)

    assert %Project{kind: :mix, project_module: nil} =
             EngineApi.call(project, Engine, :get_project)

    {project, log}
  end

  defp initial_project_diagnostics(project) do
    :ok =
      EngineApi.register_listener(project, self(), [project_compiled(), project_diagnostics()])

    EngineApi.schedule_compile(project, true)

    assert_receive project_compiled(status: :error), :timer.seconds(5)
    assert_receive project_diagnostics(diagnostics: diagnostics)
    diagnostics
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
