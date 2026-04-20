defmodule Forge.Workspace do
  @moduledoc """
  Represents the editor's workspace, which may contain one or more root folders.
  """

  alias Forge.Document

  defstruct workspace_folders: [], entropy: 1

  @type t :: %__MODULE__{
          entropy: non_neg_integer(),
          workspace_folders: [String.t()]
        }

  @spec new([String.t()]) :: t()
  def new(workspace_folders \\ []) when is_list(workspace_folders) do
    %__MODULE__{
      workspace_folders: workspace_folders,
      entropy: :rand.uniform(65_536)
    }
  end

  @spec add_folders(t(), [String.t()]) :: t()
  def add_folders(%__MODULE__{} = workspace, folder_paths) when is_list(folder_paths) do
    existing = MapSet.new(workspace.workspace_folders)

    new_folders =
      folder_paths
      |> Enum.reject(&MapSet.member?(existing, &1))

    %__MODULE__{workspace | workspace_folders: workspace.workspace_folders ++ new_folders}
  end

  @spec remove_folders(t(), [String.t()]) :: t()
  def remove_folders(%__MODULE__{} = workspace, folder_paths) when is_list(folder_paths) do
    to_remove = MapSet.new(folder_paths)

    %__MODULE__{
      workspace
      | workspace_folders:
          Enum.reject(workspace.workspace_folders, &MapSet.member?(to_remove, &1))
    }
  end

  @spec folder_path_from_uri(String.t()) :: String.t()
  def folder_path_from_uri(uri) when is_binary(uri) do
    Document.Path.from_uri(uri)
  end

  def name(%__MODULE__{workspace_folders: [first | _]}), do: Path.basename(first)
  def name(%__MODULE__{workspace_folders: []}), do: "workspace"

  def set_workspace(workspace) do
    :persistent_term.put({__MODULE__, :workspace}, workspace)
  end

  def get_workspace do
    :persistent_term.get({__MODULE__, :workspace}, nil)
  end
end
