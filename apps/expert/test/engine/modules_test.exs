defmodule Expert.Engine.ModulesTest do
  use ExUnit.Case

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Forge.Project

  describe "Engine.Modules with custom time zone database config" do
    @tag timeout: :timer.seconds(60)
    test "with_prefix/1 works when project configures custom time_zone_database" do
      # Regression test for https://github.com/elixir-lang/expert/issues/317
      #
      # When a project configures a custom time_zone_database (e.g. Tzdata),
      # the engine node inherits this config when Mix.Task.run(:loadconfig)
      # is called during project compilation (in Engine.Build.Project).
      # However, the tzdata application itself is not started on the engine node.
      #
      # This caused DateTime.add/3 to fail in Engine.Modules.rebuild_cache/0
      # because it would use the globally configured Tzdata.TimeZoneDatabase
      # which couldn't resolve time zones without the tzdata app running.
      #
      # The fix is to explicitly use Calendar.UTCOnlyTimeZoneDatabase when
      # calling DateTime.add/4 in rebuild_cache/0.

      # The :project_config fixture has:
      #   config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
      project = project(:project_config)

      # Clean workspace to ensure fresh state
      project |> Project.workspace_path() |> File.rm_rf()

      {:ok, _} =
        start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

      {:ok, _} = start_supervised(Expert.EngineBuilds)
      {:ok, _} = start_supervised(Forge.NodePortMapper)
      {:ok, _} = start_supervised({EngineSupervisor, project})
      {:ok, _, _} = EngineNode.start(project)

      EngineApi.register_listener(project, self(), [:all])

      # Trigger initial compile which runs `mix loadconfig`
      EngineApi.schedule_compile(project, true)
      assert_receive project_compiled(), :timer.seconds(30)

      # Verify the time_zone_database config was loaded on the engine node
      tz_db = EngineApi.call(project, Application, :get_env, [:elixir, :time_zone_database])
      assert tz_db == Tzdata.TimeZoneDatabase

      # Clear the module cache to force rebuild_cache/0 to be called next
      EngineApi.call(project, :persistent_term, :erase, [Engine.Modules])

      # This triggers Engine.Modules.rebuild_cache/0 which uses DateTime.add
      result = EngineApi.call(project, Engine.Modules, :with_prefix, ["Enum"])

      assert is_list(result)
      assert Enum in result
    end
  end
end
