defmodule Expert.EngineNode do
  use GenServer

  alias Expert.EngineSupervisor
  alias Expert.Progress
  alias Forge.Document
  alias Forge.Project

  require Logger

  defmodule State do
    require Logger

    defstruct [
      :project,
      :port,
      :cookie,
      :stopped_by,
      :stop_timeout,
      :started_by,
      :last_message,
      :status,
      :deps_error
    ]

    def new(%Project{} = project) do
      cookie = Node.get_cookie()

      %__MODULE__{
        project: project,
        cookie: cookie,
        status: :initializing,
        deps_error: false
      }
    end

    @dialyzer {:nowarn_function, start: 3}

    def start(%__MODULE__{} = state, paths, from, opts \\ []) do
      this_node = to_string(Node.self())
      dist_port = Forge.EPMD.dist_port()

      args =
        path_append_arguments(paths) ++
          [
            "--erl",
            "-start_epmd false -epmd_module #{Forge.EPMD}",
            "--cookie",
            state.cookie,
            "--no-halt",
            "-e",
            "System.argv() |> hd() |> Base.decode64!() |> Code.eval_string()",
            project_node_eval_string(state.project)
          ]

      mix_home_env =
        case Keyword.fetch(opts, :mix_home) do
          {:ok, mix_home} when is_binary(mix_home) -> [{"MIX_HOME", mix_home}]
          _ -> []
        end

      env =
        [
          {"EXPERT_PARENT_NODE", this_node},
          {"EXPERT_PARENT_PORT", to_string(dist_port)}
        ] ++ mix_home_env

      case Expert.Port.open_elixir(state.project, args: args, env: env) do
        {:error, _, message} ->
          Logger.error(message)
          Expert.terminate("Failed to find an elixir executable, shutting down", 1)
          {:error, :no_elixir}

        port ->
          state = %{state | port: port, started_by: from}
          {:ok, state}
      end
    end

    defp project_node_eval_string(project) do
      # We pass the child node code as --eval argument. Windows handles
      # escaped quotes and newlines differently from Unix, so to avoid
      # those kind of issues, we encode the string in base 64 and pass
      # as positional argument. Then, we use a simple --eval that decodes
      # and evaluates the string.
      project_node = Project.node_name(project)
      port_mapper = Forge.NodePortMapper

      code =
        quote do
          node = unquote(project_node)

          # We start distribution here, rather than on node boot, so that
          # -pa takes effect and Forge.EPMD is available
          node_start = Node.start(node, :longnames)

          case node_start do
            {:ok, _} ->
              :ok = unquote(port_mapper).register()
              IO.puts("ok")

            {:error, reason} ->
              IO.puts("error starting node: #{inspect(reason)}")
              IO.puts("error starting node:\n #{inspect(reason)}")
          end
        end

      code
      |> Macro.to_string()
      |> Base.encode64()
    end

    def stop(%__MODULE__{} = state, from, stop_timeout) do
      project_rpc(state, System, :stop)
      %{state | stopped_by: from, stop_timeout: stop_timeout, status: :stopping}
    end

    def halt(%__MODULE__{} = state) do
      project_rpc(state, System, :halt)
      %{state | status: :stopped}
    end

    def on_nodeup(%__MODULE__{} = state, node_name) do
      if String.starts_with?(to_string(node_name), to_string(Project.node_name(state.project))) do
        {pid, _ref} = state.started_by
        Process.monitor(pid)
        GenServer.reply(state.started_by, :ok)

        %{state | status: :started}
      else
        state
      end
    end

    def on_nodedown(%__MODULE__{} = state, node_name) do
      if node_name == Project.node_name(state.project) do
        maybe_reply_to_stopper(state)
        {:shutdown, %{state | status: :stopped}}
      else
        :continue
      end
    end

    def on_exit_status(%__MODULE__{} = state, exit_status) do
      stop_reason =
        case exit_status do
          0 ->
            Logger.info("Engine shut down", project: state.project)

            :shutdown

          _error_status when state.deps_error ->
            Logger.error(
              "Engine failed due to dependency errors (status: #{exit_status}). Last message: #{state.last_message}",
              project: state.project
            )

            {:shutdown, :deps_error}

          _error_status ->
            Logger.error(
              "Engine shut down unexpectedly, node exited with status #{exit_status}). Last message: #{state.last_message}"
            )

            {:shutdown, {:node_exit, %{status: exit_status, last_message: state.last_message}}}
        end

      new_state = %{state | status: :stopped}

      {stop_reason, new_state}
    end

    @deps_error_patterns [
      "Can't continue due to errors on dependencies",
      "Unchecked dependencies"
    ]
    def detect_deps_error(message) when is_binary(message) do
      Enum.any?(@deps_error_patterns, &String.contains?(message, &1))
    end

    def maybe_reply_to_stopper(%State{stopped_by: stopped_by} = state)
        when is_tuple(stopped_by) do
      GenServer.reply(state.stopped_by, :ok)
    end

    def maybe_reply_to_stopper(%State{}), do: :ok

    def on_monitored_dead(%__MODULE__{} = state) do
      if project_rpc(state, Node, :alive?) do
        halt(state)
      else
        %{state | status: :stopped}
      end
    end

    defp path_append_arguments(paths) do
      Enum.flat_map(paths, fn path ->
        ["-pa", Path.expand(path)]
      end)
    end

    defp project_rpc(%__MODULE__{} = state, module, function, args \\ []) do
      state.project
      |> Project.node_name()
      |> :rpc.call(module, function, args)
    end
  end

  def start(project, token \\ Progress.noop_token()) do
    start_net_kernel(project)

    node_name = Project.node_name(project)

    bootstrap_args = [
      project,
      Document.Store.entropy(),
      all_app_configs(),
      Node.self(),
      # Copy logger global metadata to engine instances.
      # Everything spawned from single expert instance will use same `instance_id`
      :logger.get_primary_config().metadata
    ]

    with {:ok, node_pid} <- EngineSupervisor.start_project_node(project),
         {:ok, {glob_paths, mix_home}} <- prepare_engine(project),
         :ok <- Progress.report(token, message: "Starting Erlang node..."),
         :ok <- start_node(project, glob_paths, mix_home: mix_home),
         :ok <- Progress.report(token, message: "Bootstrapping engine..."),
         :ok <- bootstrap(node_name, bootstrap_args),
         :ok <- ensure_apps_started(node_name, token) do
      {:ok, node_name, node_pid}
    end
  end

  defp bootstrap(node_name, bootstrap_args) do
    case :rpc.call(node_name, Engine.Bootstrap, :init, bootstrap_args) do
      :ok -> :ok
      {:error, reason} -> {:error, {:bootstrap, reason}}
    end
  end

  defp prepare_engine(project) do
    Expert.Progress.with_progress("[#{Project.name(project)}] Preparing engine", fn _token ->
      result = Expert.EngineBuilds.request_engine(project)

      {:done, result, "Engine is ready"}
    end)
  end

  defp start_net_kernel(%Project{} = project) do
    manager = Project.manager_node_name(project)
    Node.start(manager, :longnames)
  end

  defp ensure_apps_started(node, token) do
    :rpc.call(node, Engine, :ensure_apps_started, [token])
  end

  @stop_timeout 1_000

  def stop(%Project{} = project, stop_timeout \\ @stop_timeout) do
    project
    |> name()
    |> GenServer.call({:stop, stop_timeout}, stop_timeout + 100)
  end

  def child_spec(%Project{} = project) do
    %{
      id: name(project),
      start: {__MODULE__, :start_link, [project]},
      restart: :transient
    }
  end

  def start_link(%Project{} = project) do
    state = State.new(project)
    GenServer.start_link(__MODULE__, state, name: name(project))
  end

  @start_timeout 6_000

  defp start_node(project, paths, opts) do
    project
    |> name()
    |> GenServer.call({:start, paths, opts}, @start_timeout + 500)
  end

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, paths, opts}, from, %State{} = state) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    Process.send_after(self(), :maybe_start_timeout, @start_timeout)

    case State.start(state, paths, from, opts) do
      {:ok, state} ->
        {:noreply, state}

      {:error, :no_elixir} ->
        {:reply, {:error, :no_elixir}, state}
    end
  end

  @impl true
  def handle_call({:stop, stop_timeout}, from, %State{} = state) do
    state = State.stop(state, from, stop_timeout)
    {:noreply, state, stop_timeout}
  end

  @impl true
  def handle_info({:nodeup, node, _}, %State{} = state) do
    state = State.on_nodeup(state, node)
    {:noreply, state}
  end

  @impl true
  def handle_info(:maybe_start_timeout, %State{status: :started} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:maybe_start_timeout, %State{} = state) do
    GenServer.reply(state.started_by, {:error, :start_timeout})
    {:stop, :start_timeout, nil}
  end

  @impl true
  def handle_info({:nodedown, node_name, _}, %State{} = state) do
    case State.on_nodedown(state, node_name) do
      {:shutdown, new_state} ->
        {:stop, :shutdown, new_state}

      :continue ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _object, _reason}, %State{} = state) do
    state = State.on_monitored_dead(state)
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %State{port: port} = state) do
    Logger.info("Port #{inspect(port)} has exited due to: #{inspect(reason)}")
    {:noreply, %State{state | port: nil}}
  end

  @impl true
  def handle_info({:EXIT, port, _}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, %State{} = state) do
    state = State.halt(state)
    State.maybe_reply_to_stopper(state)
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, exit_status}}, %State{} = state) do
    {stop_reason, state} = State.on_exit_status(state, exit_status)

    {:stop, stop_reason, state}
  end

  @impl true
  def handle_info({_port, {:data, data}}, %State{} = state) do
    message = to_string(data)
    Logger.debug("Node port message: #{message}")

    if State.detect_deps_error(message) and not state.deps_error do
      if lsp = Expert.get_lsp() do
        send(lsp.pid, {:deps_error, state.project, %{last_message: message}})
      end

      {:noreply, %{state | last_message: message, deps_error: true}}
    else
      {:noreply, %{state | last_message: message}}
    end
  end

  @impl true
  def handle_info(msg, %State{} = state) do
    Logger.warning("Received unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  def name(%Project{} = project) do
    :"#{Project.unique_name(project)}::node_process"
  end

  @deps_apps Mix.Project.deps_apps()
  defp all_app_configs do
    Enum.map(@deps_apps, fn app_name ->
      {app_name, Application.get_all_env(app_name)}
    end)
  end
end
