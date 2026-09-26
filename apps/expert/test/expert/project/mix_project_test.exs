defmodule Expert.Project.MixProjectTest do
  use ExUnit.Case

  alias Expert.Project.MixProject
  alias Forge.Project

  @tag :tmp_dir
  test "reads runtime versions for a bare project", %{tmp_dir: root} do
    project = root |> Forge.Document.Path.to_uri() |> Project.bare()
    assert {:ok, versions} = MixProject.runtime_versions(project)
    assert versions == Forge.VM.Versions.current()
  end

  @tag :tmp_dir
  test "reads runtime versions even when mix.exs fails", %{tmp_dir: root} do
    File.write!(Path.join(root, "mix.exs"), "raise \"mix.exs must not run\"")
    project = root |> Forge.Document.Path.to_uri() |> Project.new()
    assert {:ok, versions} = MixProject.runtime_versions(project)
    assert versions == Forge.VM.Versions.current()
  end

  @tag :tmp_dir
  test "reads configuration after output from mix.exs", %{tmp_dir: root} do
    File.write!(Path.join(root, "mix.exs"), """
    IO.puts("output from mix.exs")
    defmodule ConfigurationTest.MixProject do
      use Mix.Project
      def project, do: [app: :example, version: "0.1.0", build_path: "custom_build"]
    end
    """)

    project = root |> Forge.Document.Path.to_uri() |> Project.new()
    assert {:ok, config} = MixProject.configuration(project)
    assert config.config[:app] == :example
    assert config.build_path == Path.join(root, "custom_build/test")
  end
end
