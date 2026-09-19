defmodule Engine.Commands.Reindex do
  @moduledoc """
  A simple genserver that prevents more than one reindexing job from running at the same time
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Engine.ManagerApi
  alias Engine.Progress
  alias Engine.Search.Indexer
  alias Forge.Document
  alias Forge.Project

  defmodule State do
    alias Engine.ManagerApi
    alias Engine.Search.Indexer
    alias Forge.Ast.Analysis
    alias Forge.Document

    require Logger

    @default_debounce_interval_millis 1000

    defstruct reindex_fun: nil,
              index_task: nil,
              pending_updates: %{},
              pending_uris: MapSet.new(),
              debounce_timer: nil,
              debounce_interval_millis: @default_debounce_interval_millis

    def new(reindex_fun, debounce_interval_millis \\ @default_debounce_interval_millis) do
      %__MODULE__{
        reindex_fun: reindex_fun,
        debounce_interval_millis: debounce_interval_millis
      }
    end

    def set_task(%__MODULE__{} = state, {_, _} = task) do
      %__MODULE__{state | index_task: task}
    end

    def clear_task(%__MODULE__{} = state) do
      %__MODULE__{state | index_task: nil}
    end

    def reindex_uri(%__MODULE__{} = state, uri) do
      new_state = %{state | pending_uris: MapSet.put(state.pending_uris, uri)}

      if state.debounce_timer do
        {timer, _timer_ref} = state.debounce_timer
        Process.cancel_timer(timer)
      end

      timer_ref = make_ref()

      timer =
        Process.send_after(self(), {:flush_pending, timer_ref}, state.debounce_interval_millis)

      %{new_state | debounce_timer: {timer, timer_ref}}
    end

    def flush_pending_uris(%__MODULE__{index_task: nil} = state) do
      for uri <- state.pending_uris,
          {:ok, path, entries} <- [entries_for_uri(uri)] do
        update_search_store(path, entries)
      end

      %{state | pending_uris: MapSet.new(), debounce_timer: nil}
    end

    def flush_pending_uris(%__MODULE__{} = state) do
      new_pending_updates =
        Enum.reduce(state.pending_uris, state.pending_updates, fn uri, acc ->
          case entries_for_uri(uri) do
            {:ok, path, entries} -> Map.put(acc, path, entries)
            _ -> acc
          end
        end)

      %{
        state
        | pending_uris: MapSet.new(),
          debounce_timer: nil,
          pending_updates: new_pending_updates
      }
    end

    def flush_pending_updates(%__MODULE__{} = state) do
      Enum.each(state.pending_updates, fn {path, entries} ->
        update_search_store(path, entries)
      end)

      %__MODULE__{state | pending_updates: %{}}
    end

    defp entries_for_uri(uri) do
      with {:ok, %Document{} = document, %Analysis{} = analysis} <- ensure_open(uri),
           {:ok, entries} <- Indexer.Quoted.index_with_cleanup(analysis) do
        {:ok, document.path, entries}
      else
        error ->
          Logger.error("Could not update index because #{inspect(error)}")
          error
      end
    end

    defp ensure_open(uri) do
      case Document.Store.fetch(uri, :analysis) do
        {:ok, %Document{} = document, analysis} ->
          {:ok, document, analysis}

        {:error, :not_open} ->
          # Sometimes, some operations are received long after the reindex is triggered,
          # such as new files after a batch rename
          with {:ok, _} <- Document.Store.open_temporary(uri) do
            Document.Store.fetch(uri, :analysis)
          end
      end
    end

    defp update_search_store(path, entries) do
      project = Engine.get_project()
      ManagerApi.search_store_update(project, path, entries)
    end
  end

  def start_link(opts) do
    opts =
      Keyword.validate!(opts,
        reindex_fun: &do_reindex/1,
        debounce_interval_millis: 1000
      )

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def uri(uri) do
    GenServer.cast(__MODULE__, {:reindex_uri, uri})
  end

  def perform do
    perform(Engine.get_project())
  end

  def perform(%Project{} = project) do
    GenServer.call(__MODULE__, {:perform, project})
  end

  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:fullsweep_after, 5)
    schedule_gc()

    state =
      State.new(
        Keyword.fetch!(opts, :reindex_fun),
        Keyword.fetch!(opts, :debounce_interval_millis)
      )

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:running?, _from, %State{index_task: index_task} = state) do
    {:reply, match?({_, _}, index_task), state}
  end

  def handle_call({:perform, project}, _from, %State{index_task: nil} = state) do
    index_task = spawn_monitor(fn -> state.reindex_fun.(project) end)
    {:reply, :ok, State.set_task(state, index_task)}
  end

  def handle_call({:perform, _project}, _from, state) do
    {:reply, {:error, "Already Running"}, state}
  end

  @impl GenServer
  def handle_cast({:reindex_uri, uri}, %State{} = state) do
    {:noreply, State.reindex_uri(state, uri)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{index_task: {pid, ref}} = state) do
    new_state =
      state
      |> State.flush_pending_updates()
      |> State.clear_task()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:gc, %State{} = state) do
    :erlang.garbage_collect()
    schedule_gc()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:flush_pending, timer_ref}, %State{debounce_timer: {_, timer_ref}} = state) do
    new_state = State.flush_pending_uris(state)
    {:noreply, new_state}
  end

  def handle_info({:flush_pending, _timer_ref}, %State{} = state) do
    {:noreply, state}
  end

  defp do_reindex(%Project{} = project) do
    Engine.broadcast(project_reindex_requested(project: project))

    {elapsed_us, result} =
      :timer.tc(fn ->
        with {:ok, entries, manifest} <- Indexer.create_index(project) do
          persist_index(project, entries, manifest)
        end
      end)

    Engine.broadcast(
      project_reindexed(
        project: project,
        elapsed_ms: round(elapsed_us / 1000),
        status: reindex_status(result)
      )
    )

    result
  end

  defp reindex_status(:ok), do: :success
  defp reindex_status({:ok, _}), do: :success
  defp reindex_status({:error, reason}), do: {:error, reason}
  defp reindex_status(other), do: {:error, other}

  defp schedule_gc do
    Process.send_after(self(), :gc, :timer.seconds(5))
  end

  defp persist_index(%Project{} = project, entries, manifest) do
    Progress.with_progress("Persisting index", fn _token ->
      result =
        with :ok <- replace_search_store(project, entries) do
          Indexer.commit_manifest(project, manifest)
        end

      {:done, result}
    end)
  end

  defp replace_search_store(%Project{} = project, entries) do
    ManagerApi.search_store_replace(project, entries)
  end
end
