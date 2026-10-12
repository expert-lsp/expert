defmodule Expert.Clustering do
  alias Expert.Workspace

  @spec start_net_kernel() :: {:ok, pid()} | {:error, term()}
  def start_net_kernel do
    with {:ok, manager} <- manager_node_name() do
      case start_node(manager) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  if Version.match?(System.version(), ">= 1.19.0") do
    defp start_node(manager) do
      Node.start(manager, name_domain: :longnames)
    end
  else
    defp start_node(manager) do
      Node.start(manager, :longnames)
    end
  end

  @spec manager_node_name() :: {:ok, atom()} | {:error, :not_initialized}
  def manager_node_name do
    case Workspace.get_workspace() do
      %Workspace{} = workspace ->
        workspace_name = Expert.Workspace.name(workspace)

        sanitized = Forge.Node.sanitize(workspace_name)

        node_name = :"expert-manager-#{sanitized}-#{workspace.entropy}@127.0.0.1"

        {:ok, node_name}

      nil ->
        {:error, :not_initialized}
    end
  end
end
