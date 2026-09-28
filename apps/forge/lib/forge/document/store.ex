defmodule Forge.Document.Store do
  @moduledoc """
  Backing store for source file documents.
  """

  use GenServer

  alias Forge.Document
  alias Forge.ProcessCache

  @type updater :: (Document.t() -> {:ok, Document.t()} | {:error, any()})

  @type derivations :: [derivation]
  @type derivation :: {derivation_key, derivation_fun}
  @type derivation_key :: atom()
  @type derivation_fun :: (Document.t() -> derived_value)
  @type derived_value :: any()
  @type origin :: :open | :temporary

  @type start_opts :: [start_opt]
  @type start_opt :: {:derive, derivations}

  defmodule State do
    @moduledoc false

    import Record

    alias Forge.Document
    alias Forge.Document.Store

    defstruct open: %{}, temporary_open_refs: %{}, derivation_funs: %{}

    @type t :: %__MODULE__{}

    defrecord :open_doc, document: nil, derived: %{}

    def new(opts \\ []) do
      {derivation_funs, invalid} =
        opts
        |> Keyword.validate!(derive: [])
        |> Keyword.fetch!(:derive)
        |> Enum.split_with(fn
          {atom, fun} when is_atom(atom) and is_function(fun, 1) -> true
          _ -> false
        end)

      if invalid != [] do
        raise ArgumentError, "invalid derive: #{inspect(invalid)}"
      end

      %__MODULE__{derivation_funs: Map.new(derivation_funs)}
    end

    @spec fetch(t, Forge.uri()) :: {:ok, Document.t(), t} | {:error, :not_open}
    def fetch(%__MODULE__{} = store, uri) do
      case store.open do
        %{^uri => open_doc(document: document)} -> {:ok, document, store}
        _ -> {:error, :not_open}
      end
    end

    @spec fetch(t, Forge.uri(), Store.derivation_key()) ::
            {:ok, Document.t(), Store.derived_value(), t} | {:error, :not_open}
    def fetch(%__MODULE__{} = store, uri, key) do
      case store.open do
        %{^uri => open_doc(document: document, derived: %{^key => derivation})} ->
          {:ok, document, derivation, store}

        %{^uri => open_doc(document: document, derived: derived)} ->
          derivation = derive(store, key, document)
          derived = Map.put(derived, key, derivation)
          store = put_open_doc(store, document, derived)
          {:ok, document, derivation, store}

        _ ->
          {:error, :not_open}
      end
    end

    @spec save(t, Forge.uri()) :: {:ok, t} | {:error, :not_open}
    def save(%__MODULE__{} = store, uri) do
      case store.open do
        %{^uri => open_doc(document: document, derived: derived)} ->
          document = Document.mark_clean(document)
          store = put_open_doc(store, document, derived)
          {:ok, store}

        _ ->
          {:error, :not_open}
      end
    end

    @spec open(t, Forge.uri(), String.t(), pos_integer(), String.t()) ::
            {:ok, t} | {:error, :already_open}
    def open(%__MODULE__{temporary_open_refs: refs} = store, uri, text, version, language_id)
        when is_map_key(refs, uri) do
      {_, store} =
        store
        |> maybe_cancel_ref(uri)
        |> pop_open_doc(uri)

      open(store, uri, text, version, language_id)
    end

    def open(%__MODULE__{} = store, uri, text, version, language_id) do
      case store.open do
        %{^uri => _} ->
          {:error, :already_open}

        _ ->
          document = Document.new(uri, text, version, language_id)
          store = put_open_doc(store, document)
          {:ok, store}
      end
    end

    @spec open?(t, Forge.uri()) :: boolean
    def open?(%__MODULE__{} = store, uri) do
      Map.has_key?(store.open, uri)
    end

    @spec origin(t, Forge.uri()) :: Store.origin()
    def origin(%__MODULE__{temporary_open_refs: refs}, uri) when is_map_key(refs, uri),
      do: :temporary

    def origin(%__MODULE__{}, _uri), do: :open

    @spec close(t, Forge.uri()) :: {:ok, t} | {:error, :not_open}
    def close(%__MODULE__{} = store, uri) do
      case pop_open_doc(store, uri) do
        {nil, _} ->
          {:error, :not_open}

        {_, store} ->
          {:ok, maybe_cancel_ref(store, uri)}
      end
    end

    @spec get_and_update(t, Forge.uri(), Store.updater()) ::
            {:ok, Document.t(), t} | {:error, any()}
    def get_and_update(%__MODULE__{} = store, uri, updater_fn) do
      with {:ok, open_doc(document: document)} <- Map.fetch(store.open, uri),
           {:ok, document} <- updater_fn.(document) do
        {:ok, document, put_open_doc(store, document)}
      else
        error ->
          normalize_error(error)
      end
    end

    @spec update(t, Forge.uri(), Store.updater()) :: {:ok, t} | {:error, any()}
    def update(%__MODULE__{} = store, uri, updater_fn) do
      with {:ok, _, store} <- get_and_update(store, uri, updater_fn) do
        {:ok, store}
      end
    end

    @spec open_temporarily(t, Forge.uri() | Path.t(), timeout()) ::
            {:ok, Document.t(), t} | {:error, term()}
    def open_temporarily(%__MODULE__{} = store, path_or_uri, timeout) do
      uri = Document.Path.ensure_uri(path_or_uri)
      path = Document.Path.ensure_path(path_or_uri)

      with {:ok, contents} <- File.read(path) do
        document = Document.new(uri, contents, 0)
        ref = schedule_unload(uri, timeout)

        new_store =
          store
          |> maybe_cancel_ref(uri)
          |> put_ref(uri, ref)
          |> put_open_doc(document)

        {:ok, document, new_store}
      end
    end

    @spec extend_timeout(t, Forge.uri(), timeout()) :: t
    def extend_timeout(%__MODULE__{} = store, uri, timeout) do
      case store.temporary_open_refs do
        %{^uri => ref} ->
          Process.cancel_timer(ref)
          new_ref = schedule_unload(uri, timeout)
          put_ref(store, uri, new_ref)

        _ ->
          store
      end
    end

    @spec unload(t, Forge.uri()) :: t
    def unload(%__MODULE__{} = store, uri) do
      {_, store} = pop_open_doc(store, uri)
      maybe_cancel_ref(store, uri)
    end

    defp put_open_doc(%__MODULE__{} = store, %Document{} = document, derived \\ %{}) do
      put_in(store.open[document.uri], open_doc(document: document, derived: derived))
    end

    defp pop_open_doc(%__MODULE__{} = store, uri) do
      case Map.pop(store.open, uri) do
        {open_doc() = doc, open} -> {doc, %__MODULE__{store | open: open}}
        {nil, _} -> {nil, store}
      end
    end

    defp put_ref(%__MODULE__{} = store, uri, ref) do
      put_in(store.temporary_open_refs[uri], ref)
    end

    defp maybe_cancel_ref(%__MODULE__{} = store, uri) do
      case pop_in(store.temporary_open_refs[uri]) do
        {ref, store} when is_reference(ref) ->
          Process.cancel_timer(ref)
          store

        _ ->
          store
      end
    end

    defp schedule_unload(uri, timeout) do
      Process.send_after(self(), {:unload, uri}, timeout)
    end

    defp normalize_error(:error), do: {:error, :not_open}
    defp normalize_error(e), do: e

    defp derive(%__MODULE__{} = store, key, document) do
      case store.derivation_funs do
        %{^key => fun} ->
          fun.(document)

        _ ->
          known = Map.keys(store.derivation_funs)

          raise ArgumentError,
                "No derivation for #{inspect(key)}, expected one of #{inspect(known)}"
      end
    end
  end

  @spec fetch(Forge.uri()) :: {:ok, Document.t()} | {:error, :not_open}
  def fetch(uri) do
    GenServer.call(name(), {:fetch, uri})
  end

  @spec fetch(Forge.uri(), derivation_key) ::
          {:ok, Document.t(), derived_value} | {:error, :not_open}
  def fetch(uri, key) do
    GenServer.call(name(), {:fetch, uri, key})
  end

  @spec fetch_with_origin(Forge.uri()) ::
          {:ok, Document.t(), origin()} | {:error, :not_open}
  def fetch_with_origin(uri) do
    GenServer.call(name(), {:fetch_with_origin, uri})
  end

  @spec fetch_with_origin(Forge.uri(), derivation_key) ::
          {:ok, Document.t(), derived_value, origin()} | {:error, :not_open}
  def fetch_with_origin(uri, key) do
    GenServer.call(name(), {:fetch_with_origin, uri, key})
  end

  @spec save(Forge.uri()) :: :ok | {:error, :not_open}
  def save(uri) do
    GenServer.call(name(), {:save, uri})
  end

  @spec open?(Forge.uri()) :: boolean()
  def open?(uri) do
    GenServer.call(name(), {:open?, uri})
  end

  @spec open(Forge.uri(), String.t(), String.t(), pos_integer() | nil) ::
          :ok | {:error, :already_open}
  def open(uri, text, version, language_id \\ nil) do
    GenServer.call(name(), {:open, uri, text, version, language_id})
  end

  @spec open_temporary(Forge.uri() | Path.t()) ::
          {:ok, Document.t()} | {:error, term()}

  @spec open_temporary(Forge.uri() | Path.t(), timeout()) ::
          {:ok, Document.t()} | {:error, term()}
  def open_temporary(uri, timeout \\ 5000) when is_binary(uri) do
    ProcessCache.trans(uri, 50, fn ->
      GenServer.call(name(), {:open_temporarily, uri, timeout})
    end)
  end

  @spec close(Forge.uri()) :: :ok | {:error, :not_open}
  def close(uri) do
    GenServer.call(name(), {:close, uri})
  end

  @spec get_and_update(Forge.uri(), updater) :: {:ok, Document.t()} | {:error, any()}
  def get_and_update(uri, update_fn) do
    GenServer.call(name(), {:get_and_update, uri, update_fn})
  end

  @spec update(Forge.uri(), updater) :: :ok | {:error, any()}
  def update(uri, update_fn) do
    GenServer.call(name(), {:update, uri, update_fn})
  end

  @spec start_link(start_opts) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name())
  end

  @impl GenServer
  def init(opts) do
    {:ok, State.new(opts)}
  end

  @impl GenServer
  def handle_call({:save, uri}, _from, %State{} = state) do
    {reply, new_state} =
      case State.save(state, uri) do
        {:ok, _} = success -> success
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:open, uri, text, version, language_id}, _from, %State{} = state) do
    {reply, new_state} =
      case State.open(state, uri, text, version, language_id) do
        {:ok, _} = success -> success
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:open?, uri}, _from, %State{} = state) do
    reply = State.open?(state, uri)
    {:reply, reply, state}
  end

  def handle_call({:open_temporarily, uri, timeout_ms}, _, %State{} = state) do
    {reply, new_state} =
      with {:error, :not_open} <- State.fetch(state, uri),
           {:ok, document, new_state} <- State.open_temporarily(state, uri, timeout_ms) do
        {{:ok, document}, new_state}
      else
        {:ok, document, new_state} ->
          {{:ok, document}, State.extend_timeout(new_state, uri, timeout_ms)}

        error ->
          {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:fetch, uri}, _from, %State{} = state) do
    {reply, new_state} =
      case State.fetch(state, uri) do
        {:ok, value, new_state} -> {{:ok, value}, new_state}
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:fetch, uri, key}, _from, %State{} = state) do
    {reply, new_state} =
      case State.fetch(state, uri, key) do
        {:ok, value, derived_value, new_state} -> {{:ok, value, derived_value}, new_state}
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:fetch_with_origin, uri}, _from, %State{} = state) do
    {reply, new_state} =
      case State.fetch(state, uri) do
        {:ok, document, new_state} ->
          {{:ok, document, State.origin(state, uri)}, new_state}

        error ->
          {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:fetch_with_origin, uri, key}, _from, %State{} = state) do
    {reply, new_state} =
      case State.fetch(state, uri, key) do
        {:ok, document, derived_value, new_state} ->
          {{:ok, document, derived_value, State.origin(state, uri)}, new_state}

        error ->
          {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:close, uri}, _from, %State{} = state) do
    {reply, new_state} =
      case State.close(state, uri) do
        {:ok, new_state} -> {:ok, new_state}
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:get_and_update, uri, update_fn}, _from, %State{} = state) do
    {reply, new_state} =
      case State.get_and_update(state, uri, update_fn) do
        {:ok, updated_source, new_state} -> {{:ok, updated_source}, new_state}
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  def handle_call({:update, uri, updater_fn}, _, %State{} = state) do
    {reply, new_state} =
      case State.update(state, uri, updater_fn) do
        {:ok, new_state} -> {:ok, new_state}
        error -> {error, state}
      end

    {:reply, reply, new_state}
  end

  @impl GenServer
  def handle_info({:unload, uri}, %State{} = state) do
    {:noreply, State.unload(state, uri)}
  end

  def set_entropy(entropy) do
    :persistent_term.put(entropy_key(), entropy)
    entropy
  end

  def entropy do
    case :persistent_term.get(entropy_key(), :undefined) do
      :undefined ->
        [:positive]
        |> System.unique_integer()
        |> set_entropy()

      entropy ->
        entropy
    end
  end

  def name do
    {:global, {__MODULE__, entropy()}}
  end

  defp entropy_key do
    {__MODULE__, :entropy}
  end
end
