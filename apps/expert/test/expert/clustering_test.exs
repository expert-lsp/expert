defmodule Expert.ClusteringTest do
  use ExUnit.Case

  alias Expert.Clustering
  alias Expert.Workspace

  describe "manager_node_name/0" do
    setup do
      on_exit(fn ->
        Workspace.set_workspace(nil)
      end)

      :ok
    end

    test "produces valid node name when workspace has dots in name" do
      workspace = Workspace.new(["/path/to/expert-lsp.org"])
      Workspace.set_workspace(workspace)

      assert {:ok, node_name} = Clustering.manager_node_name()

      [name_part, _host] = String.split(Atom.to_string(node_name), "@")
      refute String.contains?(name_part, ".")
    end

    test "produces valid node name when workspace has dashes in name" do
      workspace = Workspace.new(["/path/to/my-cool-project"])
      Workspace.set_workspace(workspace)

      assert {:ok, node_name} = Clustering.manager_node_name()

      assert Atom.to_string(node_name) =~ "my_cool_project"
    end

    test "uses sanitized workspace name in node name" do
      workspace = Workspace.new(["/path/to/expert-lsp.org"])
      Workspace.set_workspace(workspace)

      assert {:ok, node_name} = Clustering.manager_node_name()

      assert Atom.to_string(node_name) =~ "expert_lsp_org"
    end

    test "returns an error when no workspace is set" do
      Workspace.set_workspace(nil)

      assert {:error, :not_initialized} = Clustering.manager_node_name()
    end
  end

  describe "start_net_kernel/0" do
    setup do
      on_exit(fn ->
        Workspace.set_workspace(nil)
      end)

      :ok
    end

    test "starts net kernel compatibly when distribution is already active" do
      assert Node.alive?()
      assert is_pid(Process.whereis(:net_kernel))

      workspace = Workspace.new(["/path/to/expert-lsp.org"])
      Workspace.set_workspace(workspace)

      assert {:ok, pid} = Clustering.start_net_kernel()
      assert is_pid(pid)
    end
  end
end
