defmodule Expert.Project.Reindex do
  @moduledoc """
  Runs explicit and per-document index refreshes for one project.
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Search
  alias Forge.Document
  alias Forge.Project

  defmodule State do
    @default_debounce_interval_millis 1000

    defstruct project: nil,
              reindex_fun: nil,
              index_task: nil,
              pending_updates: %{},
              pending_documents: %{},
              debounce_timer: nil,
              debounce_interval_millis: @default_debounce_interval_millis

    def new(%Project{} = project, reindex_fun, debounce_interval_millis) do
      %__MODULE__{
        project: project,
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

    def reindex_document(%__MODULE__{} = state, %Document{} = document, imported_calls) do
      pending_documents =
        Map.put(state.pending_documents, document.uri, {document, imported_calls})

      if state.debounce_timer do
        {timer, _timer_ref} = state.debounce_timer
        Process.cancel_timer(timer)
      end

      timer_ref = make_ref()

      timer =
        Process.send_after(self(), {:flush_pending, timer_ref}, state.debounce_interval_millis)

      %{state | pending_documents: pending_documents, debounce_timer: {timer, timer_ref}}
    end

    def flush_pending_documents(%__MODULE__{index_task: nil} = state) do
      for {path, entries} <- pending_entries(state) do
        update_search_store(state.project, path, entries)
      end

      %{state | pending_documents: %{}, debounce_timer: nil}
    end

    def flush_pending_documents(%__MODULE__{} = state) do
      pending_updates = Enum.into(pending_entries(state), state.pending_updates)

      %{state | pending_documents: %{}, debounce_timer: nil, pending_updates: pending_updates}
    end

    def flush_pending_updates(%__MODULE__{} = state) do
      Enum.each(state.pending_updates, fn {path, entries} ->
        update_search_store(state.project, path, entries)
      end)

      %__MODULE__{state | pending_updates: %{}}
    end

    defp pending_entries(%__MODULE__{} = state) do
      for {_uri, {document, imported_calls}} <- state.pending_documents do
        {:ok, path, entries} = Search.Indexer.document(state.project, document, imported_calls)
        {path, entries}
      end
    end

    defp update_search_store(%Project{} = project, path, entries) do
      Search.Store.update(project, path, entries)
    end
  end

  def start_link(%Project{} = project), do: start_link(project, [])

  def start_link(%Project{} = project, opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts,
        reindex_fun: &do_reindex/1,
        debounce_interval_millis: 1000
      )

    GenServer.start_link(__MODULE__, [project, opts], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::reindex"

  def perform(%Project{} = project), do: GenServer.call(name(project), :perform)
  def running?(%Project{} = project), do: GenServer.call(name(project), :running?)

  @impl GenServer
  def init([%Project{} = project, opts]) do
    EngineApi.register_listener(project, self(), [file_compiled(), filesystem_event()])

    Process.flag(:fullsweep_after, 5)
    schedule_gc()

    state =
      State.new(
        project,
        Keyword.fetch!(opts, :reindex_fun),
        Keyword.fetch!(opts, :debounce_interval_millis)
      )

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:running?, _from, %State{index_task: index_task} = state) do
    {:reply, match?({_, _}, index_task), state}
  end

  def handle_call(:perform, _from, %State{index_task: nil} = state) do
    index_task = spawn_monitor(fn -> state.reindex_fun.(state.project) end)
    {:reply, :ok, State.set_task(state, index_task)}
  end

  def handle_call(:perform, _from, state) do
    {:reply, {:error, "Already Running"}, state}
  end

  @impl GenServer
  def handle_info(
        file_compiled(document: %Document{} = document, imported_calls: imported_calls),
        %State{} = state
      ) do
    {:noreply, State.reindex_document(state, document, imported_calls)}
  end

  def handle_info(filesystem_event(uri: uri, event_type: :deleted), %State{} = state) do
    path = Document.Path.ensure_path(uri)
    Search.Store.clear(state.project, path)
    {:noreply, state}
  end

  def handle_info(filesystem_event(), %State{} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{index_task: {pid, ref}} = state) do
    new_state =
      state
      |> State.flush_pending_updates()
      |> State.clear_task()

    {:noreply, new_state}
  end

  def handle_info(:gc, %State{} = state) do
    :erlang.garbage_collect()
    schedule_gc()
    {:noreply, state}
  end

  def handle_info({:flush_pending, timer_ref}, %State{debounce_timer: {_, timer_ref}} = state) do
    {:noreply, State.flush_pending_documents(state)}
  end

  def handle_info({:flush_pending, _timer_ref}, %State{} = state) do
    {:noreply, state}
  end

  defp do_reindex(%Project{} = project) do
    EngineApi.broadcast(project, project_reindex_requested(project: project))

    {elapsed_us, result} =
      :timer.tc(fn -> Search.Indexer.create_index(project) end)

    EngineApi.broadcast(
      project,
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
end
