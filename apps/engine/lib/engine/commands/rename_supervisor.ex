defmodule Engine.Commands.RenameSupervisor do
  @moduledoc """
  DynamicSupervisor for managing rename progress tracking GenServers.

  Each rename operation spawns a transient child that tracks progress
  and shuts down when the rename is complete.
  """

  use DynamicSupervisor

  alias Engine.Commands.Rename

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Starts a new rename progress tracker.

  ## Parameters

  - `uri_to_expected_operation` - Map of URIs to expected messages (file_changed/file_saved)
  - `paths_to_reindex` - List of URIs that need to be reindexed after rename
  - `paths_to_delete` - List of URIs whose entries should be deleted from the index
  - `on_update_progress` - Callback function receiving (increment, message)
  - `on_complete` - Callback function called when rename is complete
  """
  def start_renaming(
        uri_to_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_update_progress,
        on_complete
      ) do
    DynamicSupervisor.start_child(
      __MODULE__,
      Rename.child_spec(
        uri_to_expected_operation,
        paths_to_reindex,
        paths_to_delete,
        on_update_progress,
        on_complete
      )
    )
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
