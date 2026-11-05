defmodule Expert.EngineNode.Builder do
  @moduledoc """
  Builds the engine node for a project.
  """
  use GenServer

  alias Forge.Project

  require Logger

  defmodule State do
    defstruct [
      :project,
      :build,
      :owner,
      :key,
      :port,
      :buffer,
      :restart,
      output_lines: [],
      attempts: 0
    ]
  end

  # Keep the most recent N non-empty output lines from the build subprocess.
  # On failure we forward this buffer to the user so the actual error message
  # is visible instead of just the bottom of the stacktrace.
  @max_output_lines 50

  @max_attempts 1

  def child_spec({project, build, owner, key}) do
    %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [{project, build, owner, key}]},
      restart: :temporary
    }
  end

  def start_link({project, build, owner, key}) do
    GenServer.start_link(__MODULE__, {project, build, owner, key})
  end

  @impl GenServer
  def init({project, build, owner, key}) do
    state = %State{
      project: project,
      build: build,
      owner: owner,
      key: key,
      buffer: ""
    }

    {:ok, state, {:continue, :build}}
  end

  @impl GenServer
  def handle_continue(:build, %State{} = state) do
    {:ok, port} = start_build(state.project, state.build)
    {:noreply, %State{state | port: port}}
  end

  @impl GenServer
  def handle_info({_port, {:data, {:noeol, line}}}, %State{} = state) do
    {:noreply, %State{state | buffer: state.buffer <> line}}
  end

  def handle_info({_port, {:data, {:eol, line}}}, %State{} = state) do
    chunk = state.buffer <> line
    line = String.trim(chunk)
    state = %State{state | buffer: ""}

    state =
      if line == "" do
        state
      else
        %State{state | output_lines: [line | state.output_lines]}
      end

    case parse_engine_meta(line) do
      {:ok, tooling_env, engine_path} ->
        Logger.info("Engine available at: #{engine_path}", project: state.project)

        Logger.info("ebin paths:\n#{inspect(ebin_paths(engine_path), pretty: true)}",
          project: state.project
        )

        notify(state, {:ok, {ebin_paths(engine_path), tooling_env}})
        {:stop, :normal, state}

      :error ->
        if detect_deps_error(line) do
          handle_deps_error(line, state)
        else
          Logger.debug("Engine build output: #{line}", project: state.project)
          {:noreply, state}
        end
    end
  end

  def handle_info({port, {:exit_status, _status}}, %State{port: port, restart: :force} = state) do
    restart_build(state)
  end

  def handle_info({port, {:exit_status, 0}}, %State{port: port} = state) do
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, _status}}, %State{restart: :force} = state) do
    {:noreply, state}
  end

  def handle_info({:build_result, result}, state) do
    notify(state, result)
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    Logger.error("Engine build script exited with status: #{status}", project: state.project)

    notify(state, {:error, "Build script exited with status: #{status}", captured_output(state)})
    {:stop, :normal, state}
  end

  def handle_info({_port, {:exit_status, _status}}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, port, _reason}, %State{port: port, restart: :force} = state) do
    restart_build(state)
  end

  def handle_info({:EXIT, port, reason}, %State{port: port} = state) when reason != :normal do
    Logger.error("Engine build script exited with reason: #{inspect(reason)}",
      project: state.project
    )

    notify(state, {:error, reason, captured_output(state)})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  if Mix.env() == :test do
    # In test environment, Expert depends on the Engine app, so we look for it
    # in the expert build path.
    @excluded_apps [:patch, :nimble_parsec]
    @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

    def start_build(_, _build, _opts \\ []) do
      entries =
        [Mix.Project.build_path(), "**/ebin"]
        |> Forge.Path.glob()
        |> Enum.filter(fn entry ->
          Enum.any?(@allowed_apps, &String.contains?(entry, to_string(&1)))
        end)

      send(self(), {:build_result, {:ok, {entries, nil}}})
      {:ok, :fake_port}
    end

    def close_port(_port), do: :ok
  else
    # In dev and prod environments, the engine source code is included in the
    # Expert release, and we build it on the fly for the project elixir+opt
    # versions if it was not built yet.
    def start_build(%Project{} = project, build, opts \\ []) do
      elixir = Keyword.fetch!(build, :elixir)
      env = Keyword.fetch!(build, :env)

      port = launch_engine_builder(project, elixir, env, opts)
      {:ok, port}
    end

    defp close_port(port), do: Port.close(port)
  end

  def launch_engine_builder(project, elixir, env, opts \\ []) do
    expert_priv = :code.priv_dir(:expert)
    packaged_engine_source = Path.join([expert_priv, "engine_source", "apps", "engine"])

    engine_source =
      "EXPERT_ENGINE_PATH"
      |> System.get_env(packaged_engine_source)
      |> Path.expand()

    build_engine_script = Path.join(expert_priv, "build_engine.exs")
    cache_dir = Forge.Path.expert_cache_dir()

    args = [
      build_engine_script,
      "--source-path",
      engine_source,
      "--vsn",
      Expert.vsn(),
      "--cache-dir",
      cache_dir
    ]

    args =
      if opts[:force] do
        args ++ ["--force"]
      else
        args
      end

    Logger.info("Preparing engine", project: project)

    Process.flag(:trap_exit, true)

    # The build script finds the user's archives from these before it replaces
    # them with Expert's own.
    user_mix_env =
      for var <- ["MIX_HOME", "MIX_ARCHIVES"], value = System.get_env(var), do: {var, value}

    env = [{"MIX_ENV", "prod"} | user_mix_env] ++ env

    Expert.Port.open_elixir_with_env(elixir, env,
      args: args,
      cd: Project.root_path(project),
      line: 4096
    )
  end

  defp notify(state, result) do
    send(state.owner, {:engine_build_complete, state.key, self(), result})
  end

  defp restart_build(%State{} = state) do
    {:ok, port} = start_build(state.project, state.build, force: true)
    {:noreply, %State{state | port: port, restart: nil}}
  end

  defp ebin_paths(base_path) do
    Forge.Path.glob([base_path, "lib/**/ebin"])
  end

  defp handle_deps_error(line, %State{} = state) do
    if state.attempts < @max_attempts do
      Logger.warning(
        "Detected dependency errors during engine build, retrying... (attempt #{state.attempts + 1}/#{@max_attempts})",
        project: state.project
      )

      close_port(state.port)
      {:noreply, %State{state | attempts: state.attempts + 1, restart: :force}}
    else
      Logger.error("Maximum build attempts reached. Failing the build.", project: state.project)

      notify(
        state,
        {:error, "Build failed due to dependency errors after #{@max_attempts} attempts", line}
      )

      {:stop, :normal, state}
    end
  end

  defp parse_engine_meta("engine_meta:" <> meta) do
    meta = String.trim(meta)

    with {:ok, binary} <- Base.decode64(meta),
         %{tooling_env: tooling_env, engine_path: engine_path} <- :erlang.binary_to_term(binary),
         true <- valid_tooling_env?(tooling_env) do
      {:ok, tooling_env, engine_path}
    else
      _ -> :error
    end
  end

  defp parse_engine_meta(_), do: :error

  defp valid_tooling_env?(tooling_env) do
    is_list(tooling_env) and
      Enum.all?(tooling_env, fn
        {key, value} when is_binary(key) and is_binary(value) -> true
        _ -> false
      end)
  end

  @deps_error_patterns [
    "Can't continue due to errors on dependencies",
    "Unchecked dependencies",
    "Hex dependency resolution failed"
  ]
  defp detect_deps_error(message) when is_binary(message) do
    Enum.any?(@deps_error_patterns, &String.contains?(message, &1))
  end

  defp captured_output(%State{output_lines: lines}) do
    total = length(lines)
    body = lines |> Enum.take(@max_output_lines) |> Enum.reverse() |> Enum.join("\n")

    if total > @max_output_lines do
      "...(#{total - @max_output_lines} earlier line(s) omitted)\n#{body}"
    else
      body
    end
  end
end
