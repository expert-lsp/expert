defmodule Expert.Project.Indexer do
  @moduledoc """
  Coordinates project index refreshes after successful compiles.
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Integrations.Cache
  alias Expert.Project.EngineRuntime
  alias Expert.Search
  alias Forge.Project

  require Logger

  defmodule State do
    defstruct [
      :project,
      :task,
      :mode,
      :task_supervisor,
      :create_index,
      :update_index,
      pending?: false,
      record_integrations?: false
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
    state = State.new(project, opts)
    Cache.put_compiled(project, false)
    Logger.info("Starting index warmup task")
    {:ok, start_warmup(state)}
  end

  defp start_warmup(%State{} = state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        with :ok <- Search.Store.enable(state.project) do
          warmup(state.project, Search.Store.load_status(state.project))
        end
      end)

    %State{
      state
      | task: {:warmup, task},
        record_integrations?: not Configuration.compilation_enabled?()
    }
  end

  @impl GenServer
  def handle_cast(:refresh, %State{} = state) do
    {:noreply, start_or_queue_refresh(state)}
  end

  @impl GenServer
  def handle_info(project_compiled(status: status), %State{} = state)
      when status in [:success, :successful, :error] do
    state = %State{state | record_integrations?: status != :error}
    Cache.put_compiled(state.project, true)
    {:noreply, start_or_queue_refresh(state)}
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

  defp start_or_queue_refresh(%State{task: {:warmup, task}} = state) do
    Task.shutdown(task, :brutal_kill)
    start_refresh(%State{state | task: nil})
  end

  defp start_or_queue_refresh(%State{task: nil} = state), do: start_refresh(state)
  defp start_or_queue_refresh(%State{} = state), do: %State{state | pending?: true}

  defp start_refresh(%State{} = state) do
    mode = if EngineRuntime.available?(state.project), do: :engine, else: :local
    if mode == :local, do: Cache.put_compiled(state.project, false)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        with :ok <- Search.Store.enable(state.project) do
          case Search.Store.load_status(state.project) do
            :empty -> create_index(state, mode)
            _ -> update_index(state, mode)
          end
        end
      end)

    %State{
      state
      | task: {:refresh, task},
        mode: mode,
        pending?: false,
        record_integrations?: state.record_integrations? or mode == :local
    }
  end

  defp update_index(%State{} = state, mode) do
    case update_project_index(state, mode) do
      {:error, {:store, reason}} ->
        Logger.warning(
          "Could not persist incremental index update, rebuilding full index: #{inspect(reason)}"
        )

        create_index(state, mode)

      result ->
        result
    end
  end

  defp finish_task(%State{pending?: true} = state, _result), do: start_refresh(state)

  defp finish_task(%State{} = state, :ok) do
    with {:error, reason} <- maybe_record_integrations(state) do
      Logger.warning("Could not record search integrations: #{inspect(reason)}")
    end

    if state.mode == :engine and EngineRuntime.available?(state.project) do
      EngineApi.broadcast(state.project, project_index_ready(project: state.project))
    end

    %State{state | task: nil, mode: nil, record_integrations?: false}
  end

  defp finish_task(%State{} = state, _result) do
    %State{state | task: nil, mode: nil, record_integrations?: false}
  end

  defp maybe_record_integrations(%State{record_integrations?: true, mode: :engine} = state) do
    Search.Indexer.record_integrations(state.project)
  end

  defp maybe_record_integrations(%State{record_integrations?: true} = state) do
    Search.Indexer.record_integrations(state.project, false)
  end

  defp maybe_record_integrations(%State{}), do: :ok

  defp log_result(kind, :ok), do: Logger.info("Index #{kind} finished")
  defp log_result(kind, result), do: Logger.warning("Index #{kind} returned #{inspect(result)}")

  defp warmup(project, :empty), do: Search.Indexer.warmup(project)

  defp warmup(project, status) when status in [:stale, :ready] do
    if Configuration.compilation_enabled?() do
      :ok
    else
      Search.Indexer.update_from_disk(project)
    end
  end

  defp create_index(state, :engine), do: state.create_index.(state.project)
  defp create_index(state, :local), do: Search.Indexer.warmup(state.project)

  defp update_project_index(state, :engine), do: state.update_index.(state.project)
  defp update_project_index(state, :local), do: Search.Indexer.update_from_disk(state.project)
end
