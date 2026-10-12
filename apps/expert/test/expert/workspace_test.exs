defmodule Expert.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Expert.Workspace

  describe "name/1" do
    test "returns the basename of the first workspace folder" do
      workspace = Workspace.new(["/path/to/my-project"])
      assert Workspace.name(workspace) == "my-project"
    end

    test "returns folder name with periods" do
      workspace = Workspace.new(["/path/to/expert-lsp.org"])
      assert Workspace.name(workspace) == "expert-lsp.org"
    end

    test "returns folder name with special characters" do
      workspace = Workspace.new(["/path/to/project@name:test"])
      assert Workspace.name(workspace) == "project@name:test"
    end

    test "returns folder name with spaces" do
      workspace = Workspace.new(["/path/to/my project"])
      assert Workspace.name(workspace) == "my project"
    end

    test "returns folder name with UTF-8 characters" do
      workspace = Workspace.new(["/path/to/プロジェクト"])
      assert Workspace.name(workspace) == "プロジェクト"
    end

    test "returns folder name with uppercase letters unchanged" do
      workspace = Workspace.new(["/path/to/MyProject"])
      assert Workspace.name(workspace) == "MyProject"
    end

    test "returns workspace when no folders are configured" do
      workspace = Workspace.new([])
      assert Workspace.name(workspace) == "workspace"
    end
  end
end
