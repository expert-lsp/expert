defmodule Expert.Clustering do
  alias Forge.Workspace

  def start_net_kernel do
    with {:ok, manager} <- manager_node_name() do
      case Node.start(manager, :longnames) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec manager_node_name() :: {:ok, atom()} | {:error, :not_initialized}
  def manager_node_name do
    case Workspace.get_workspace() do
      %Workspace{} = workspace ->
        workspace_name = Forge.Workspace.name(workspace)

        sanitized = Forge.Node.sanitize(workspace_name)

        node_name = :"expert-manager-#{sanitized}-#{workspace.entropy}@127.0.0.1"

        {:ok, node_name}

      nil ->
        {:error, :not_initialized}
    end
  end
end
