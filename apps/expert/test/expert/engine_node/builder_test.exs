defmodule Expert.EngineNode.BuilderTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineNode.Builder

  setup do
    {:ok, project: project()}
  end

  defp build do
    [elixir: ~c"/usr/bin/elixir", env: []]
  end

  defp start_builder(project, key \\ :builder_test) do
    Builder.start_link({project, build(), self(), key})
  end

  test "retries with --force when a dep error is detected", %{project: project} do
    test_pid = self()
    attempt_counter = :counters.new(1, [])

    patch(Builder, :start_build, fn _project, _build, opts ->
      :counters.add(attempt_counter, 1, 1)
      current_attempt = :counters.get(attempt_counter, 1)

      case current_attempt do
        1 ->
          refute opts[:force]
          send(test_pid, {:attempt, 1})
          {:ok, :fake_port}

        2 ->
          assert opts[:force]
          send(test_pid, {:attempt, 2})
          send(self(), {:build_result, {:ok, {test_ebin_entries(), nil}}})
          {:ok, :fake_port}
      end
    end)

    {:ok, builder_pid} = start_builder(project)

    assert_receive {:attempt, 1}, 1_000
    send(builder_pid, {nil, {:data, {:eol, "Unchecked dependencies for environment dev:"}}})

    assert_receive {:attempt, 2}, 1_000

    assert_receive {:engine_build_complete, :builder_test, ^builder_pid, {:ok, {paths, nil}}},
                   5_000

    assert paths == test_ebin_entries()
  end

  test "returns error after exhausting max retry attempts", %{project: project} do
    test_pid = self()

    patch(Builder, :start_build, fn _project, _build, _opts ->
      send(test_pid, :build_started)
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = start_builder(project)
    error_line = "Unchecked dependencies for environment dev:"

    assert_receive :build_started, 1_000
    send(builder_pid, {nil, {:data, {:eol, error_line}}})

    assert_receive :build_started, 1_000
    send(builder_pid, {nil, {:data, {:eol, error_line}}})

    assert_receive {:engine_build_complete, :builder_test, ^builder_pid,
                    {:error, "Build failed due to dependency errors after 1 attempts",
                     ^error_line}},
                   5_000
  end

  test "parses engine_meta after unrelated output", %{project: project} do
    patch(Builder, :start_build, fn _project, _build, _opts ->
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = start_builder(project)

    engine_path = Path.join(System.tmp_dir!(), "dev_ns")
    mix_home = Path.join(System.tmp_dir!(), "mix_home")

    meta =
      %{mix_home: mix_home, engine_path: engine_path}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    send(builder_pid, {nil, {:data, {:eol, "Rewriting 0 config scripts."}}})
    send(builder_pid, {nil, {:data, {:eol, "engine_meta:#{meta}"}}})

    assert_receive {:engine_build_complete, :builder_test, ^builder_pid,
                    {:ok, {paths, ^mix_home}}},
                   5_000

    assert paths == Forge.Path.glob([engine_path, "lib/**/ebin"])
  end

  test "parses engine_meta across chunks", %{project: project} do
    patch(Builder, :start_build, fn _project, _build, _opts ->
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = start_builder(project)

    engine_path = Path.join(System.tmp_dir!(), "dev_ns")
    mix_home = Path.join(System.tmp_dir!(), "mix_home")

    meta =
      %{mix_home: mix_home, engine_path: engine_path}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    {first, second} = String.split_at("engine_meta:#{meta}", 8)

    send(builder_pid, {nil, {:data, {:noeol, first}}})
    send(builder_pid, {nil, {:data, {:eol, second}}})

    assert_receive {:engine_build_complete, :builder_test, ^builder_pid,
                    {:ok, {paths, ^mix_home}}},
                   5_000

    assert paths == Forge.Path.glob([engine_path, "lib/**/ebin"])
  end

  @excluded_apps [:patch, :nimble_parsec]
  @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

  defp test_ebin_entries do
    [Mix.Project.build_path(), "**/ebin"]
    |> Forge.Path.glob()
    |> Enum.filter(fn entry ->
      Enum.any?(@allowed_apps, &String.contains?(entry, to_string(&1)))
    end)
  end
end
