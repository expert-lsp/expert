defmodule Forge.ProjectTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Patch

  alias Forge.Document
  alias Forge.Project

  defp test_project do
    root = Forge.Document.Path.to_uri(__DIR__)
    Project.new(root)
  end

  describe "name/1" do
    test "returns the folder name unchanged" do
      patch(Project, :folder_name, "my-project.org")
      assert Project.name(test_project()) == "my-project.org"
    end

    test "preserves special characters" do
      patch(Project, :folder_name, "foo.bar")
      assert Project.name(test_project()) == "foo.bar"
    end

    test "preserves capital letters" do
      patch(Project, :folder_name, "FooBar")
      assert Project.name(test_project()) == "FooBar"
    end

    test "preserves leading numbers" do
      patch(Project, :folder_name, "3bar")
      assert Project.name(test_project()) == "3bar"
    end
  end

  describe "from_folders/1" do
    test "returns an empty list for no folders" do
      assert Project.from_folders([]) == []
    end

    @tag :tmp_dir
    test "returns only mix and bare elixir projects", %{tmp_dir: tmp_dir} do
      mix_project_path = Path.join(tmp_dir, "mix_project")
      bare_project_path = Path.join(tmp_dir, "bare_project")
      other_project_path = Path.join(tmp_dir, "other_project")

      File.mkdir_p!(mix_project_path)
      File.mkdir_p!(bare_project_path)
      File.mkdir_p!(other_project_path)

      File.write!(Path.join(mix_project_path, "mix.exs"), "defmodule MixProject do\nend\n")
      File.write!(Path.join(bare_project_path, "test.ex"), "defmodule BareProject do\nend\n")
      File.write!(Path.join(other_project_path, "README.md"), "hello\n")

      folders = [
        %{uri: Document.Path.to_uri(mix_project_path)},
        %{uri: Document.Path.to_uri(bare_project_path)},
        %{uri: Document.Path.to_uri(other_project_path)}
      ]

      assert folders
             |> Project.from_folders()
             |> Enum.map(&Project.root_path/1)
             |> Enum.sort() == Enum.sort([mix_project_path, bare_project_path])

      [bare_project, mix_project] =
        folders
        |> Project.from_folders()
        |> Enum.sort_by(&Project.root_path/1)

      assert Project.kind(bare_project) == :bare
      assert Project.kind(mix_project) == :mix
    end

    @tag :tmp_dir
    test "ignores folders that do not exist or are not elixir projects", %{tmp_dir: tmp_dir} do
      other_project_path = Path.join(tmp_dir, "other_project")
      missing_project_path = Path.join(tmp_dir, "missing_project")

      File.mkdir_p!(other_project_path)
      File.write!(Path.join(other_project_path, "README.md"), "hello\n")

      folders = [
        %{uri: Document.Path.to_uri(other_project_path)},
        %{uri: Document.Path.to_uri(missing_project_path)}
      ]

      assert Project.from_folders(folders) == []
    end
  end

  describe "ensure_workspace/1" do
    @tag :tmp_dir
    test "creates .gitignore when the workspace directory already exists", %{tmp_dir: tmp_dir} do
      project = tmp_dir |> Document.Path.to_uri() |> Project.new()
      workspace_path = Project.workspace_path(project)
      gitignore_path = Project.workspace_path(project, ".gitignore")

      File.mkdir_p!(workspace_path)

      assert :ok = Project.ensure_workspace(project)
      assert File.regular?(gitignore_path)
    end
  end

  describe "new/1" do
    @tag :tmp_dir
    test "assigns bare kind to non-mix elixir projects", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.ex"), "defmodule BareProject do\nend\n")

      project = tmp_dir |> Document.Path.to_uri() |> Project.new()

      assert Project.kind(project) == :bare
    end

    @tag :tmp_dir
    test "assigns mix kind to mix projects", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MixProject do\nend\n")

      project = tmp_dir |> Document.Path.to_uri() |> Project.new()

      assert Project.kind(project) == :mix
    end

    @tag :tmp_dir
    test "never produces nil kind, even for non-elixir directories", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "README.md"), "hello\n")

      project = tmp_dir |> Document.Path.to_uri() |> Project.new()

      assert project.kind in [:mix, :bare]
      assert Project.kind(project) == :bare
    end
  end
end
