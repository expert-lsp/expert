defmodule Engine.Commands.Rename do
  @moduledoc """
  Tracks rename progress and triggers reindexing after rename operations complete.

  This GenServer is started when a rename operation begins. It tracks expected file
  operations (file_changed, file_saved) and when all operations are received, it
  reindexes the modified files and clears old entries from the search index.

  This is necessary because after a rename, the search index still contains the old
  module names. Without reindexing, subsequent renames won't find the new entries.
  """

  use GenServer

  import Forge.EngineApi.Messages

  alias Engine.Commands.Reindex
  alias Engine.ManagerApi
  alias Forge.Document
  alias Forge.EngineApi.Messages

  require Logger

  @timeout :timer.seconds(30)

  defmodule State do
    @moduledoc false

    @type uri_to_expected_operation :: %{
            Forge.uri() => Messages.file_changed() | Messages.file_saved()
          }

    @type t :: %__MODULE__{
            uri_to_expected_operation: uri_to_expected_operation(),
            paths_to_reindex: list(Forge.uri()),
            paths_to_delete: list(Forge.uri()),
            on_update_progress: (integer(), String.t() -> :ok),
            on_complete: (-> :ok)
          }

    defstruct uri_to_expected_operation: %{},
              paths_to_reindex: [],
              paths_to_delete: [],
              on_update_progress: nil,
              on_complete: nil

    def new(
          uri_to_expected_operation,
          paths_to_reindex,
          paths_to_delete,
          on_update_progress,
          on_complete
        ) do
      %__MODULE__{
        uri_to_expected_operation: uri_to_expected_operation,
        paths_to_reindex: paths_to_reindex,
        paths_to_delete: paths_to_delete,
        on_update_progress: on_update_progress,
        on_complete: on_complete
      }
    end

    def update_progress(%__MODULE__{} = state, file_changed(uri: uri)) do
      consume_operation(state, uri)
    end

    def update_progress(%__MODULE__{} = state, file_saved(uri: uri)) do
      consume_operation(state, uri)
    end

    defp consume_operation(%__MODULE__{} = state, uri) do
      new_uri_with_expected_operation =
        maybe_pop_expected_operation(
          state.uri_to_expected_operation,
          uri,
          state.on_update_progress
        )

      if Enum.empty?(new_uri_with_expected_operation) do
        reindex_all_modified_files(state)
        state.on_complete.()
      end

      %__MODULE__{state | uri_to_expected_operation: new_uri_with_expected_operation}
    end

    def in_progress?(%__MODULE__{} = state) do
      state.uri_to_expected_operation != %{}
    end

    defp maybe_pop_expected_operation(uri_to_operation, uri, on_update_progress) do
      case uri_to_operation do
        %{^uri => _expected_message} ->
          on_update_progress.(1, "")
          Map.delete(uri_to_operation, uri)

        _ ->
          uri_to_operation
      end
    end

    defp reindex_all_modified_files(%__MODULE__{} = state) do
      Enum.each(state.paths_to_reindex, fn uri ->
        Reindex.uri(uri)
        state.on_update_progress.(1, "reindexing")
      end)

      Enum.each(state.paths_to_delete, fn uri ->
        project = Engine.get_project()
        ManagerApi.search_store_clear(project, Document.Path.ensure_path(uri))
        state.on_update_progress.(1, "deleting old index")
      end)
    end
  end

  @spec child_spec(
          %{Forge.uri() => Messages.file_changed() | Messages.file_saved()},
          list(Forge.uri()),
          list(Forge.uri()),
          (integer(), String.t() -> :ok),
          (-> :ok)
        ) :: Supervisor.child_spec()
  def child_spec(
        uri_to_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_update_progress,
        on_complete
      ) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,
         [
           uri_to_expected_operation,
           paths_to_reindex,
           paths_to_delete,
           on_update_progress,
           on_complete
         ]},
      restart: :transient
    }
  end

  def start_link(
        uri_to_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_update_progress,
        on_complete
      ) do
    Logger.info(
      "Starting rename tracking: #{map_size(uri_to_expected_operation)} operations, " <>
        "#{length(paths_to_reindex)} to reindex, #{length(paths_to_delete)} to delete"
    )

    state =
      State.new(
        uri_to_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_update_progress,
        on_complete
      )

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @impl true
  def init(state) do
    case Engine.Api.Proxy.start_buffering() do
      :ok ->
        Process.send_after(self(), :timeout, @timeout)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc """
  Updates the rename progress with a file operation message.

  This should be called when files are changed or saved during rename.
  Returns `:ok` if the message was processed, `{:error, :not_in_rename_progress}`
  if no rename is in progress.
  """
  @spec update_progress(Messages.file_changed() | Messages.file_saved()) ::
          :ok | {:error, :not_in_rename_progress}
  def update_progress(message) do
    pid = Process.whereis(__MODULE__)

    if pid && Process.alive?(pid) do
      GenServer.cast(__MODULE__, {:update_progress, message})
    else
      {:error, :not_in_rename_progress}
    end
  end

  @impl true
  def handle_call(:in_progress?, _from, state) do
    {:reply, State.in_progress?(state), state}
  end

  @impl true
  def handle_cast({:update_progress, message}, state) do
    new_state = State.update_progress(state, message)

    if State.in_progress?(new_state) do
      {:noreply, new_state}
    else
      Logger.info("Rename process completed.")
      {:stop, :normal, new_state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning(
      "Rename tracking timed out with #{map_size(state.uri_to_expected_operation)} pending operations"
    )

    state.on_complete.()
    {:stop, :normal, state}
  end
end
