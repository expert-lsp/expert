defmodule Expert.Project.Indexer do
  @moduledoc """
  Coordinates project index refreshes after successful compiles.
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Project.Node
  alias Expert.Search
  alias Forge.Project

  require Logger

  defmodule State do
    defstruct [
      :project,
      :task,
      :task_supervisor,
      :create_index,
      :update_index,
      :initial_compile?,
      pending?: false
    ]

    def new(%Project{} = project, opts) do
      %__MODULE__{
        project: project,
        task_supervisor: Keyword.fetch!(opts, :task_supervisor),
        create_index: Keyword.fetch!(opts, :create_index),
        update_index: Keyword.fetch!(opts, :update_index),
        initial_compile?: Keyword.get(opts, :initial_compile?, false)
      }
    end
  end

  def start_link(%Project{} = project) do
    start_link(project, [])
  end

  def start_link(%Project{} = project, opts) when is_list(opts) do
    opts =
      Keyword.merge(
        [
          task_supervisor: task_supervisor_name(project),
          create_index: &Search.Indexer.create_index/1,
          update_index: &Search.Indexer.update_index/1,
          initial_compile?: false
        ],
        opts
      )

    GenServer.start_link(__MODULE__, [project, opts], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  def child_spec([%Project{} = project | opts]) when is_list(opts) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project, opts]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::indexer"

  def task_supervisor_name(%Project{} = project) do
    :"#{Project.unique_name(project)}::indexer_task_supervisor"
  end

  @impl GenServer
  def init([%Project{} = project, opts]) do
    EngineApi.register_listener(project, self(), [project_compiled()])
    {:ok, State.new(project, opts), {:continue, :maybe_initial_compile}}
  end

  @impl GenServer
  def handle_continue(:maybe_initial_compile, %State{initial_compile?: true} = state) do
    force? = Search.Store.load_status(state.project) not in [:stale, :ready]
    Node.trigger_build(state.project, force?)
    {:noreply, state}
  end

  def handle_continue(:maybe_initial_compile, %State{} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(project_compiled(status: status), %State{} = state)
      when status in [:success, :successful, :error] do
    {:noreply, start_or_queue_index(state)}
  end

  def handle_info({ref, result}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    log_index_result(result)

    {:noreply, complete_index(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{task: %Task{ref: ref}} = state
      ) do
    Logger.error("Search indexing failed: #{Exception.format_exit(reason)}")

    {:noreply, complete_index(state, {:error, reason})}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp start_or_queue_index(%State{task: %Task{}} = state), do: %State{state | pending?: true}

  defp start_or_queue_index(%State{} = state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run_index(state.project, state.create_index, state.update_index)
      end)

    %State{state | task: task, pending?: false}
  end

  defp complete_index(%State{pending?: true} = state, _result),
    do: start_or_queue_index(%State{state | task: nil, pending?: false})

  defp complete_index(%State{} = state, :ok) do
    EngineApi.broadcast(state.project, project_index_ready(project: state.project))
    %State{state | task: nil}
  end

  defp complete_index(%State{} = state, _result) do
    %State{state | task: nil}
  end

  defp run_index(%Project{} = project, create_index, update_index) do
    with :ok <- Search.Store.enable(project) do
      persist_index(project, Search.Store.load_status(project), create_index, update_index)
    end
  end

  defp persist_index(%Project{} = project, :empty, create_index, _update_index) do
    persist_full_index(project, create_index)
  end

  defp persist_index(%Project{} = project, _status, create_index, update_index) do
    persist_incremental_index(project, create_index, update_index)
  end

  defp persist_full_index(%Project{} = project, create_index) do
    create_index.(project)
  end

  defp persist_incremental_index(%Project{} = project, create_index, update_index) do
    case update_index.(project) do
      {:error, {:store, reason}} ->
        Logger.warning(
          "Could not persist incremental index update, rebuilding full index: #{inspect(reason)}"
        )

        persist_index(project, :empty, create_index, update_index)

      result ->
        result
    end
  end

  defp log_index_result(:ok), do: :ok

  defp log_index_result({:error, reason}) do
    Logger.warning("Could not refresh index: #{inspect(reason)}")
  end

  defp log_index_result(other) do
    Logger.warning("Unexpected index refresh result: #{inspect(other)}")
  end
end
