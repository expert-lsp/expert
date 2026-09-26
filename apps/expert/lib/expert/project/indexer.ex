defmodule Expert.Project.Indexer do
  @moduledoc """
  Coordinates project index refreshes after successful compiles.
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
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
      pending?: false
    ]

    def new(project, opts) do
      %__MODULE__{
        project: project,
        task_supervisor: Keyword.fetch!(opts, :task_supervisor),
        create_index: Keyword.fetch!(opts, :create_index),
        update_index: Keyword.fetch!(opts, :update_index)
      }
    end
  end

  def start_link(%Project{} = project), do: start_link(project, [])

  def start_link(%Project{} = project, opts) do
    opts =
      Keyword.merge(
        [
          task_supervisor: task_supervisor_name(project),
          create_index: &Search.Indexer.create_index/1,
          update_index: &Search.Indexer.update_index/1
        ],
        opts
      )

    GenServer.start_link(__MODULE__, [project, opts], name: name(project))
  end

  def child_spec(%Project{} = project), do: child_spec([project])

  def child_spec([%Project{} = project | opts]) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project, opts]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::indexer"

  def task_supervisor_name(%Project{} = project) do
    :"#{Project.unique_name(project)}::indexer_task_supervisor"
  end

  def refresh(%Project{} = project), do: GenServer.cast(name(project), :refresh)

  @impl GenServer
  def init([project, opts]) do
    Process.flag(:trap_exit, true)
    {:ok, State.new(project, opts), {:continue, :warmup}}
  end

  @impl GenServer
  def handle_continue(:warmup, %State{} = state) do
    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        with :ok <- Search.Store.enable(state.project),
             :empty <- Search.Store.load_status(state.project) do
          Search.Indexer.warmup(state.project)
        else
          status when status in [:stale, :ready] -> :ok
          error -> error
        end
      end)

    {:noreply, %State{state | task: {:warmup, task}}}
  end

  @impl GenServer
  def handle_cast(:refresh, %State{task: {:warmup, task}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, start_refresh(%State{state | task: nil})}
  end

  def handle_cast(:refresh, %State{task: nil} = state) do
    {:noreply, start_refresh(state)}
  end

  def handle_cast(:refresh, %State{} = state) do
    {:noreply, %State{state | pending?: true}}
  end

  @impl GenServer
  def handle_info({ref, result}, %State{task: {kind, %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    log_result(kind, result)
    {:noreply, finish_task(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{task: {kind, %Task{ref: ref}}} = state
      ) do
    Logger.error("Index #{kind} failed: #{Exception.format_exit(reason)}")
    {:noreply, finish_task(state, {:error, reason})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{task: {_kind, task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  defp start_refresh(%State{} = state) do
    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        with :ok <- Search.Store.enable(state.project) do
          case Search.Store.load_status(state.project) do
            :empty -> state.create_index.(state.project)
            _ -> update_index(state)
          end
        end
      end)

    %State{state | task: {:refresh, task}, pending?: false}
  end

  defp update_index(%State{} = state) do
    case state.update_index.(state.project) do
      {:error, {:store, reason}} ->
        Logger.warning(
          "Could not persist incremental index update, rebuilding full index: #{inspect(reason)}"
        )

        state.create_index.(state.project)

      result ->
        result
    end
  end

  defp finish_task(%State{pending?: true} = state, _result), do: start_refresh(state)

  defp finish_task(%State{task: {:refresh, _}} = state, :ok) do
    EngineApi.broadcast(state.project, project_index_ready(project: state.project))
    %State{state | task: nil}
  end

  defp finish_task(%State{} = state, _result), do: %State{state | task: nil}

  defp log_result(kind, :ok), do: Logger.info("Index #{kind} finished")
  defp log_result(kind, result), do: Logger.warning("Index #{kind} returned #{inspect(result)}")
end
