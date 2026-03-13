defmodule Expert.EngineBuilds do
  use GenServer

  alias Expert.EngineNode.Builder
  alias Forge.Project

  require Logger

  defmodule State do
    defstruct ready: %{}, pending: %{}
  end

  @type build_result :: {[String.t()], String.t() | nil}

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec request_engine(Project.t()) :: {:ok, build_result()} | {:error, term()}
  def request_engine(%Project{} = project) do
    with {:ok, key, build} <- resolve_build(project) do
      GenServer.call(__MODULE__, {:request_engine, key, project, build}, :infinity)
    end
  end

  @impl GenServer
  def init(_) do
    {:ok, %State{}}
  end

  @impl GenServer
  def handle_call({:request_engine, key, project, build}, from, state) do
    case Map.fetch(state.ready, key) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      :error ->
        case Map.fetch(state.pending, key) do
          {:ok, pending} ->
            pending = %{pending | waiters: [from | pending.waiters]}
            pending_map = Map.put(state.pending, key, pending)

            {:noreply, %State{state | pending: pending_map}}

          :error ->
            case start_builder(project, build, key) do
              {:ok, pid} ->
                pending = %{pid: pid, ref: Process.monitor(pid), waiters: [from]}
                pending_map = Map.put(state.pending, key, pending)

                {:noreply, %State{state | pending: pending_map}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  @impl GenServer
  def handle_info({:engine_build_complete, key, pid, result}, state) do
    case pop_pending_by_key(state, key, pid) do
      {:ok, pending, state} ->
        Process.demonitor(pending.ref, [:flush])
        reply_all(pending.waiters, result)

        state =
          case result do
            {:ok, engine} -> %State{state | ready: Map.put(state.ready, key, engine)}
            _ -> state
          end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case pop_pending_by_ref(state, ref, pid) do
      {:ok, pending, state} ->
        reply_all(pending.waiters, {:error, reason})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp resolve_build(%Project{} = project) do
    with {:ok, elixir, env} <- Expert.Port.project_executable(project, "elixir"),
         {:ok, erl, _env} <- Expert.Port.project_executable(project, "erl") do
      Logger.info("Using path: #{System.get_env("PATH")}", project: project)
      Logger.info("Found elixir executable at #{elixir}", project: project)
      Logger.info("Found erl executable at #{erl}", project: project)

      with {:ok, key} <- build_key(project, elixir, env) do
        {:ok, key, [elixir: elixir, env: env]}
      end
    else
      {:error, name, message} ->
        Logger.error(message, project: project)
        Expert.terminate("Failed to find an #{name} executable, shutting down", 1)
        {:error, message}
    end
  end

  defp build_key(%Project{} = project, elixir, env) do
    case toolchain_versions(project, elixir, env) do
      {output, 0} ->
        output = String.trim(output)

        with {:ok, binary} <- Base.decode64(output),
             {elixir_version, erts_version} <- :erlang.binary_to_term(binary) do
          {:ok, {elixir_version, erts_version}}
        else
          _ -> {:error, "Failed to determine Elixir/OTP runtime for project"}
        end

      {output, status} ->
        {:error,
         "Failed to determine Elixir/OTP runtime for project: #{String.trim(output)} (status #{status})"}
    end
  end

  defp toolchain_versions(%Project{} = project, elixir, env) do
    cmd =
      "{System.version(), to_string(:erlang.system_info(:version))} |> :erlang.term_to_binary() |> Base.encode64() |> IO.write()"

    System.cmd(to_string(elixir), ["--eval", cmd],
      env: env,
      cd: Project.root_path(project),
      stderr_to_stdout: true
    )
  end

  defp start_builder(project, build, key) do
    DynamicSupervisor.start_child(
      Expert.EngineBuild.DynamicSupervisor.name(),
      {Builder, {project, build, self(), key}}
    )
  end

  defp pop_pending_by_key(state, key, pid) do
    case state.pending do
      %{^key => %{pid: ^pid} = pending} ->
        pending_map = Map.delete(state.pending, key)
        {:ok, pending, %State{state | pending: pending_map}}

      %{} ->
        :error
    end
  end

  defp pop_pending_by_ref(state, ref, pid) do
    case Enum.find(state.pending, fn {_key, pending} ->
           pending.ref == ref and pending.pid == pid
         end) do
      {key, pending} ->
        pending_map = Map.delete(state.pending, key)
        {:ok, pending, %State{state | pending: pending_map}}

      nil ->
        :error
    end
  end

  defp reply_all(waiters, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
  end
end
