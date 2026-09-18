defmodule Engine.Compilation.TraceBuffer do
  use GenServer

  alias Engine.Search.Indexer.Beams

  @table __MODULE__

  defstruct []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def discard, do: call(:discard)

  def drain_definitions, do: call(:drain_definitions, :infinity)

  def record_module(path, binary) when is_binary(path) and is_binary(binary) do
    true = :ets.insert(@table, {Forge.Path.native(path), binary})
    :ok
  end

  def record_module(_path, _binary), do: :ok

  def record_module(path, binary, module)
      when is_binary(path) and is_binary(binary) and is_atom(module) do
    GenServer.cast(__MODULE__, {:record_module, path, binary, module})
  end

  def record_module(_path, _binary, _module), do: :ok

  @impl GenServer
  def init(%__MODULE__{} = state) do
    _ = :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:discard, _from, %__MODULE__{} = state) do
    clear_live()
    {:reply, :ok, state}
  end

  def handle_call(:drain_definitions, _from, %__MODULE__{} = state) do
    definitions = definitions_by_path(live_events())
    clear_live()
    {:reply, {:ok, definitions}, state}
  end

  @impl GenServer
  def handle_cast({:record_module, path, binary, module}, state) do
    definitions =
      case Beams.debug_metadata_from_binary(binary) do
        {:ok, metadata} ->
          for {def, kind, meta, _} <- metadata[:definitions], do: {def, kind, meta}

        _ ->
          []
      end

    true =
      :ets.insert(
        @table,
        {Forge.Path.native(path), binary, module, definitions}
      )

    {:noreply, state}
  rescue
    _ ->
      record_module(path, binary)
      {:noreply, state}
  end

  defp call(message, timeout \\ 5_000), do: GenServer.call(__MODULE__, message, timeout)

  defp live_events do
    :ets.tab2list(@table)
  end

  defp clear_live do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp definitions_by_path(events) do
    events
    |> Enum.flat_map(&definitions_from_event/1)
    |> Enum.group_by(& &1.path)
  end

  defp definitions_from_event({path, binary}) do
    case Beams.extract_definitions_from_binary(binary, path) do
      {:ok, entries} -> entries
      :error -> []
    end
  end

  defp definitions_from_event({path, binary, module, definitions}) do
    case Beams.extract_definitions_from_binary(binary, path, module, definitions) do
      {:ok, entries} -> entries
      :error -> []
    end
  end
end
