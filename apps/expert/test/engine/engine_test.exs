defmodule EngineTest do
  use ExUnit.Case
  use Forge.Test.EventualAssertions

  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Forge.Document
  alias Forge.Project

  def start_project(%Project{} = project) do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!({Expert.EngineSupervisor, project})
    assert {:ok, _, _} = EngineNode.start(project)
    :ok
  end

  def engine_cwd(project) do
    project
    |> EngineApi.call(File, :cwd!, [])
    |> normalize_path_separators()
  end

  defp normalize_path_separators(path) when is_binary(path) do
    if Forge.OS.windows?() do
      String.replace(path, "/", "\\")
    else
      path
    end
  end

  describe "detecting an umbrella app" do
    test "it changes the directory to the root if it's started in a subapp" do
      parent_project = project(:umbrella)

      subapp_project =
        [fixtures_path(), "umbrella", "apps", "first"]
        |> Path.join()
        |> Document.Path.to_uri()
        |> Project.new()

      start_project(subapp_project)

      assert_eventually(
        engine_cwd(subapp_project) == Project.root_path(parent_project),
        250
      )
    end

    test "keeps the current directory if it's started in the parent app" do
      parent_project = project(:umbrella)
      start_project(parent_project)

      assert_eventually(
        engine_cwd(parent_project) == Project.root_path(parent_project),
        250
      )
    end
  end
end
