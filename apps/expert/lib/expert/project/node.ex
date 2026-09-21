defmodule Expert.Project.Node do
  @moduledoc """
  A genserver responsible for starting the remote node and cleaning up the build directory if it crashes
  """

  use GenServer

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.Progress
  alias Forge.Project

  require Logger

  defmodule State do
    defstruct [:project, :node, :supervisor_pid]

    def new(project, node, supervisor_pid) do
      %__MODULE__{project: project, node: node, supervisor_pid: supervisor_pid}
    end
  end

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  def name(%Project{} = project) do
    :"#{Project.unique_name(project)}::node"
  end

  def node_name(%Project{} = project) do
    project
    |> name()
    |> GenServer.call(:node_name)
  end

  def trigger_build(%Project{} = project, force? \\ true) do
    project
    |> name()
    |> GenServer.cast({:trigger_build, force?})
  end

  @impl GenServer
  def init(%Project{} = project) do
    project_name = Project.name(project)

    result =
      Progress.with_progress("[#{project_name}] Starting engine node", fn token ->
        result = start_node(project, token)

        {:done, result, "Engine node started"}
      end)

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, {:bootstrap, reason}} ->
        message = bootstrap_error_message(reason)
        {:stop, {:shutdown, {:bootstrap_error, message}}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:node_name, _from, %State{} = state) do
    {:reply, state.node, state}
  end

  @impl GenServer
  def handle_cast({:trigger_build, force?}, %State{} = state) do
    EngineApi.schedule_compile(state.project, force?)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:nodedown, _}, %State{} = state) do
    Logger.warning("The node has died. Restarting after deleting the build directory")

    case delete_build_artifacts(state.project) do
      :ok ->
        # The remote dispatcher lost its registrations. Restart listeners to register again.
        {:stop, :normal, state}

      error ->
        {:stop, error, state}
    end
  end

  # private api

  defp start_node(%Project{} = project, token) do
    with {:ok, node, node_pid} <- EngineNode.start(project, token) do
      Node.monitor(node, true)
      {:ok, State.new(project, node, node_pid)}
    end
  end

  defp delete_build_artifacts(%Project{} = project) do
    build_path = Project.versioned_build_path(project)

    case File.rm_rf(build_path) do
      {:ok, _deleted} -> :ok
      error -> error
    end
  end

  defp bootstrap_error_message(reason) do
    case reason do
      :eacces -> "Project directory has insufficient permissions. It needs to be writable."
      :erofs -> "Project is in a read-only filesystem"
      :enospc -> "No disk space available"
      _ -> "Unable to bootstrap engine: #{inspect(reason)}"
    end
  end
end
