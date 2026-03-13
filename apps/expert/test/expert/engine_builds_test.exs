defmodule Expert.EngineBuildsTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineBuilds
  alias Expert.EngineNode.Builder
  alias Forge.Project

  setup do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(EngineBuilds)
    :ok
  end

  test "concurrent callers with same toolchain wait for single build" do
    test_pid = self()
    project_a = project(:project)
    project_b = project(:umbrella)
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(test_pid, {:build_started, self()})

      receive do
        :release_build ->
          send(self(), {:build_result, {:ok, result}})
          {:ok, :fake_port}
      end
    end)

    task_a = Task.async(fn -> EngineBuilds.request_engine(project_a) end)
    task_b = Task.async(fn -> EngineBuilds.request_engine(project_b) end)

    assert_receive {:build_started, builder_pid}, 1_000
    send(builder_pid, :release_build)

    assert {:ok, ^result} = Task.await(task_a, 1_000)
    assert {:ok, ^result} = Task.await(task_b, 1_000)
    assert :counters.get(calls, 1) == 1
  end

  test "reuses the cached build for later callers" do
    project = project()
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:ok, result}})
      {:ok, :fake_port}
    end)

    assert {:ok, ^result} = EngineBuilds.request_engine(project)
    assert {:ok, ^result} = EngineBuilds.request_engine(project)
    assert :counters.get(calls, 1) == 1
  end

  test "builds separately for different toolchains" do
    test_pid = self()
    project_a = project(:project)
    project_b = project(:umbrella)
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn project, _elixir, _env ->
      output =
        project
        |> Project.root_path()
        |> Path.basename()
        |> case do
          "project" -> runtime_key_output("1.17.3", "15.2.7.4")
          "umbrella" -> runtime_key_output("1.18.0", "16.0.0")
        end

      {output, 0}
    end)

    patch(Builder, :start_build, fn project, _build, _opts ->
      tag = project |> Project.root_path() |> Path.basename()
      send(test_pid, {:builder_started, tag, self()})

      receive do
        {:release_builder, ^tag} ->
          send(self(), {:build_result, {:ok, result}})
          {:ok, :fake_port}
      end
    end)

    task_a = Task.async(fn -> EngineBuilds.request_engine(project_a) end)
    task_b = Task.async(fn -> EngineBuilds.request_engine(project_b) end)

    assert_receive {:builder_started, tag_a, pid_a}, 1_000
    assert_receive {:builder_started, tag_b, pid_b}, 1_000

    assert Enum.sort([tag_a, tag_b]) == ["project", "umbrella"]

    send(pid_a, {:release_builder, tag_a})
    send(pid_b, {:release_builder, tag_b})

    assert {:ok, ^result} = Task.await(task_a, 1_000)
    assert {:ok, ^result} = Task.await(task_b, 1_000)
  end

  test "does not cache failed builds" do
    project = project()
    calls = :counters.new(1, [])

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:error, :build_failed}})
      {:ok, :fake_port}
    end)

    assert {:error, :build_failed} = EngineBuilds.request_engine(project)
    assert {:error, :build_failed} = EngineBuilds.request_engine(project)
    assert :counters.get(calls, 1) == 2
  end

  test "does not reuse a build when two projects share the same shim path but different runtime versions" do
    project_a = project(:project)
    project_b = project(:umbrella)
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/shims/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/shims/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn project, _elixir, _env ->
      output =
        project
        |> Project.root_path()
        |> Path.basename()
        |> case do
          "project" -> runtime_key_output("1.17.3", "15.2.7.4")
          "umbrella" -> runtime_key_output("1.18.0", "16.0.0")
        end

      {output, 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:ok, result}})
      {:ok, :fake_port}
    end)

    assert {:ok, ^result} = EngineBuilds.request_engine(project_a)
    assert {:ok, ^result} = EngineBuilds.request_engine(project_b)
    assert :counters.get(calls, 1) == 2
  end

  test "returns error when toolchain versions check fails" do
    project = project()

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {"elixir: command not found", 1}
    end)

    assert {:error,
            "Failed to determine Elixir/OTP runtime for project: elixir: command not found (status 1)"} =
             EngineBuilds.request_engine(project)
  end

  test "returns error when runtime key output is invalid" do
    project = project()

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {"not-valid-base64!!!", 0}
    end)

    assert {:error, "Failed to determine Elixir/OTP runtime for project"} =
             EngineBuilds.request_engine(project)
  end

  test "notifies all waiters when builder crashes" do
    test_pid = self()
    project_a = project(:project)
    project_b = project(:umbrella)
    calls = :counters.new(1, [])

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(EngineBuilds, :toolchain_versions, fn _project, _elixir, _env ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(test_pid, {:builder_pid, self()})
      {:ok, :fake_port}
    end)

    task_a = Task.async(fn -> EngineBuilds.request_engine(project_a) end)
    task_b = Task.async(fn -> EngineBuilds.request_engine(project_b) end)

    assert_receive {:builder_pid, pid}, 1_000

    Process.exit(pid, :kill)

    assert {:error, :killed} = Task.await(task_a, 1_000)
    assert {:error, :killed} = Task.await(task_b, 1_000)
    assert :counters.get(calls, 1) == 1
  end

  defp test_ebin_entries do
    ["/tmp/dev_ns/lib/engine/ebin"]
  end

  defp runtime_key_output(elixir_version, erts_version) do
    {elixir_version, erts_version}
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end
end
