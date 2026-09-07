defmodule Expert.Search.Store do
  @moduledoc """
  Manager-node persistent store for search entries.
  """

  use GenServer

  alias Expert.Search.Store
  alias Expert.Search.Store.State
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger

  @backend Application.compile_env(:expert, :search_store_backend, Store.Backends.Sqlite)
  @flush_interval_ms Application.compile_env(:expert, :search_store_quiescent_period_ms, 2500)

  def stop(%Project{} = project), do: GenServer.stop(name(project))
  def loaded?(%Project{} = project), do: GenServer.call(name(project), :loaded?)
  def load_status(%Project{} = project), do: GenServer.call(name(project), :load_status)

  def replace(%Project{} = project, entries),
    do: GenServer.call(name(project), {:replace, entries}, :infinity)

  def apply_index_update(%Project{} = project, updated_entries, paths_to_clear) do
    GenServer.call(
      name(project),
      {:apply_index_update, updated_entries, paths_to_clear},
      :infinity
    )
  end

  @spec exact(Project.t(), Entry.subject_query(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def exact(%Project{} = project, subject \\ :_, constraints) do
    call_or_default(project, {:exact, subject, constraints}, [])
  end

  @spec exact_many(Project.t(), [Entry.subject()], Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def exact_many(%Project{} = project, subjects, constraints) when is_list(subjects) do
    call_or_default(project, {:exact_many, subjects, constraints}, [])
  end

  @spec by_caller(Project.t(), Entry.caller(), Path.t(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def by_caller(%Project{} = project, caller, path, constraints \\ [])
      when is_binary(caller) and is_binary(path) do
    call_or_default(project, {:by_caller, caller, path, constraints}, [])
  end

  @spec prefix(Project.t(), String.t(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def prefix(%Project{} = project, prefix, constraints) do
    call_or_default(project, {:prefix, prefix, constraints}, [])
  end

  @spec parent(Project.t(), Entry.t()) :: {:ok, Entry.t()} | {:error, term()} | nil
  def parent(%Project{} = project, %Entry{} = entry) do
    call_or_default(project, {:parent, entry}, nil)
  end

  @spec siblings(Project.t(), Entry.t()) :: {:ok, [Entry.t()]} | {:error, term()} | []
  def siblings(%Project{} = project, %Entry{} = entry) do
    call_or_default(project, {:siblings, entry}, [])
  end

  @spec fuzzy(Project.t(), Entry.subject(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def fuzzy(%Project{} = project, subject, constraints) do
    call_or_default(project, {:fuzzy, subject, constraints}, [])
  end

  @spec all(Project.t(), [Entry.constraint() | {:paths, [Path.t()]}]) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def all(%Project{} = project, constraints \\ []) do
    call_or_default(project, {:all, constraints}, [])
  end

  @spec path_to_ids(Project.t()) :: %{Path.t() => Entry.entry_id()} | {:error, term()}
  def path_to_ids(%Project{} = project) do
    call_or_default(project, :path_to_ids, %{})
  end

  @spec resolve_mfa(Project.t(), module(), atom(), non_neg_integer()) ::
          {module(), atom(), non_neg_integer(), boolean(), boolean()}
  def resolve_mfa(%Project{} = project, module, function, arity) do
    call_or_default(
      project,
      {:resolve_mfa, module, function, arity},
      {module, function, arity, false, false}
    )
  end

  def clear(%Project{} = project, path),
    do: GenServer.call(name(project), {:update, path, []}, :infinity)

  def update(%Project{} = project, path, entries),
    do: GenServer.call(name(project), {:update, path, entries}, :infinity)

  def destroy(%Project{} = project), do: GenServer.call(name(project), :destroy)

  # we need higher timeout for this, as it performs optimization via PRAGMA optimize
  # on existing database
  def enable(%Project{} = project),
    do: GenServer.call(name(project), :enable, :timer.seconds(30))

  @spec start_link(Project.t()) :: GenServer.on_start()
  def start_link(%Project{} = project), do: start_link(project, backend())

  @spec start_link(Project.t(), module()) :: GenServer.on_start()
  def start_link(%Project{} = project, backend) when is_atom(backend) do
    GenServer.start_link(__MODULE__, [project, backend], name: name(project))
  end

  def child_spec(init_args) when is_list(init_args) do
    [project | _] = normalize_init_args(init_args)

    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, normalize_init_args(init_args)}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::search_store"

  @impl GenServer
  def init([%Project{} = project, backend]) do
    Process.flag(:fullsweep_after, 5)
    schedule_gc()
    {:ok, State.new(project, backend), {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, %State{} = state) do
    {_reply, state} = load_store(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:flush_updates, {_, %State{} = state}) do
    state = flush_buffered_updates_or_keep(state)
    ref = schedule_flush()
    {:noreply, {ref, state}}
  end

  def handle_info(:gc, state) do
    :erlang.garbage_collect()
    schedule_gc()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:enable, _from, %State{} = state) do
    {reply, state} = load_store(state)
    {:reply, reply, state}
  end

  def handle_call(:enable, _from, {ref, %State{loaded?: true} = state}) do
    {:reply, :ok, {ref, state}}
  end

  def handle_call(:enable, _from, {ref, %State{} = state}) do
    case State.load(state) do
      {:ok, _status, state} ->
        :persistent_term.put({__MODULE__, Project.unique_name(state.project), :enabled?}, true)
        {:reply, :ok, {ref, state}}

      {:error, _reason} = error ->
        {:reply, error, {ref, state}}
    end
  end

  def handle_call(:enable, _from, state), do: {:reply, :ok, state}

  def handle_call({:replace, entries}, _from, {ref, %State{} = state}) do
    {reply, new_state} =
      case State.replace(state, entries) do
        {:ok, new_state} -> {:ok, State.drop_buffered_updates(new_state)}
        {:error, _} = error -> {error, state}
      end

    {:reply, reply, {ref, new_state}}
  end

  def handle_call(
        {:apply_index_update, updated_entries, paths_to_clear},
        _from,
        {ref, %State{} = state}
      ) do
    {reply, new_state} =
      case State.apply_index_update(state, updated_entries, paths_to_clear) do
        {:ok, new_state} -> {:ok, State.drop_buffered_updates(new_state)}
        {:error, _} = error -> {error, state}
      end

    {:reply, reply, {ref, new_state}}
  end

  def handle_call({:exact, subject, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.exact(subject, constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call({:exact_many, subjects, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.exact_many(subjects, constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call({:by_caller, caller, path, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.by_caller(caller, path, constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call({:prefix, prefix, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.prefix(prefix, constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call({:fuzzy, subject, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.fuzzy(subject, constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call({:all, constraints}, _from, {ref, %State{} = state}) do
    state
    |> State.all(constraints)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, {ref, state}})
  end

  def handle_call(:path_to_ids, _from, {ref, %State{} = state}) do
    {:reply, State.path_to_ids(state), {ref, state}}
  end

  def handle_call({:update, path, entries}, _from, {ref, %State{} = state}) do
    {reply, new_ref, new_state} = do_update(state, ref, path, entries)
    {:reply, reply, {new_ref, new_state}}
  end

  def handle_call({:parent, entry}, _from, {_, %State{} = state} = orig_state) do
    state
    |> State.parent(entry)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, orig_state})
  end

  def handle_call({:siblings, entry}, _from, {_, %State{} = state} = orig_state) do
    state
    |> State.siblings(entry)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, orig_state})
  end

  def handle_call(
        {:resolve_mfa, module, function, arity},
        _from,
        {_, %State{} = state} = orig_state
      ) do
    state
    |> State.resolve_mfa(module, function, arity)
    |> maybe_broadcast_loading(state)
    |> then(&{:reply, &1, orig_state})
  end

  def handle_call(:on_stop, _, {ref, %State{} = state}) do
    state = flush_buffered_updates_or_keep(state)
    State.drop(state)
    {:reply, :ok, {ref, state}}
  end

  def handle_call(:loaded?, _, {ref, %State{loaded?: loaded?} = state}),
    do: {:reply, loaded?, {ref, state}}

  def handle_call(:loaded?, _, %State{loaded?: loaded?} = state), do: {:reply, loaded?, state}

  def handle_call(:load_status, _, {ref, %State{load_status: status} = state}),
    do: {:reply, status, {ref, state}}

  def handle_call(:load_status, _, %State{load_status: status} = state),
    do: {:reply, status, state}

  def handle_call(:destroy, _, {ref, %State{} = state}) do
    {reply, state} =
      case State.destroy(state) do
        {:ok, state} ->
          :persistent_term.erase({__MODULE__, Project.unique_name(state.project), :enabled?})
          {:ok, state}

        {:error, _} = error ->
          {error, state}
      end

    {:reply, reply, {ref, state}}
  end

  def handle_call(message, _from, %State{} = state) do
    Logger.warning("Received #{inspect(message)}, but the search store isn't enabled yet.")
    {:reply, {:error, {:not_enabled, message}}, state}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    state = flush_buffered_updates_or_keep(state)
    state
  end

  def terminate(_reason, {_, state}) do
    state = flush_buffered_updates_or_keep(state)
    state
  end

  defp normalize_init_args([%Project{} = project]), do: [project, backend()]

  defp normalize_init_args([%Project{} = project, backend]) when is_atom(backend),
    do: [project, backend]

  def backend, do: @backend

  defp do_update(state, old_ref, path, entries) do
    {:ok, schedule_flush(old_ref), State.buffer_updates(state, path, entries)}
  end

  defp schedule_flush(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    schedule_flush()
  end

  defp schedule_flush(_), do: schedule_flush()
  defp schedule_flush, do: Process.send_after(self(), :flush_updates, @flush_interval_ms)

  defp load_store(%State{} = state) do
    case State.load(state) do
      {:ok, _status, state} ->
        :persistent_term.put({__MODULE__, Project.unique_name(state.project), :enabled?}, true)
        server_state = {nil, state}
        {:ok, server_state}

      {:error, reason} = error ->
        Logger.error("Could not enable search store: #{inspect(reason)}")
        {error, state}
    end
  end

  defp flush_buffered_updates_or_keep(%State{} = state) do
    case State.flush_buffered_updates(state) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("Could not flush search index updates: #{inspect(reason)}")
        state
    end
  end

  defp schedule_gc, do: Process.send_after(self(), :gc, :timer.seconds(5))

  defp call_or_default(%Project{} = project, call, default) do
    if enabled?(project) do
      GenServer.call(name(project), call, :infinity)
    else
      default
    end
  catch
    :exit, _ -> default
  end

  defp enabled?(%Project{} = project) do
    :persistent_term.get({__MODULE__, Project.unique_name(project), :enabled?}, false)
  end

  defp maybe_broadcast_loading({:error, :loading} = result, _state), do: result

  defp maybe_broadcast_loading(result, _state), do: result
end
