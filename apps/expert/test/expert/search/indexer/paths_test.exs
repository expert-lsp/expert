defmodule Expert.Search.Indexer.PathsTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.EngineApi
  alias Expert.Search.Indexer.Paths
  alias Forge.Project

  setup do
    patch(EngineApi, :project_configuration, fn _engine_project, configured_project ->
      Engine.Mix.project_configuration(configured_project)
    end)

    :ok
  end

  defp source_paths(project), do: Paths.for_project(project).source_paths

  describe "for_project/1" do
    @tag :tmp_dir
    test "discovers files locally from configuration without executing project code", %{
      tmp_dir: root
    } do
      with_env("MIX_BUILD_ROOT", Path.join(root, "manager_build"))
      with_env("MIX_BUILD_PATH", Path.join(root, "manager_build/dev"))
      project = root |> Forge.Document.Path.to_uri() |> Project.bare()
      project = %{project | kind: :mix}
      build = Path.join(root, ".expert/build/target/test")
      source = Path.join(root, "lib/source.ex")
      generated = Path.join(root, "target_build/generated.ex")
      dependency_source = Path.join(root, "vendor/lib/dependency.ex")
      project_beam = Path.join([build, "lib", "example", "ebin", "Example.beam"])
      dependency_beam = Path.join([build, "lib", "active", "ebin", "Active.beam"])
      inactive_beam = Path.join([build, "lib", "inactive", "ebin", "Inactive.beam"])
      disabled_beam = Path.join([build, "lib", "disabled", "ebin", "Disabled.beam"])

      for path <- [
            source,
            generated,
            dependency_source,
            project_beam,
            dependency_beam,
            inactive_beam,
            disabled_beam
          ],
          do: write_file!(path, "fixture")

      info = %{
        config: [
          app: :example,
          deps: [
            {:active, "*", only: :prod, targets: :board},
            {:inactive, "*", only: :dev},
            {:disabled, "*", app: false}
          ]
        ],
        project_config: [build_path: "ignored_configured_build"],
        build_path: build,
        deps_path: Path.join(root, "vendor"),
        apps_paths: nil,
        dependency_apps: {:error, :unavailable},
        env: :prod,
        target: :board,
        build_root: "target_build"
      }

      patch(EngineApi, :call, fn _, _, _, _ ->
        flunk("Discovery must not run through engine RPC")
      end)

      cwd = File.cwd!()
      paths = Paths.for_project(project, fn ^project -> {:ok, info} end)
      assert paths.source_paths == [source]

      assert Enum.sort(paths.beam_paths) ==
               Enum.sort([project_beam, dependency_beam])

      assert paths.applications[Path.dirname(project_beam)] == :example
      assert File.cwd!() == cwd
      assert System.get_env("MIX_BUILD_PATH") == Path.join(root, "manager_build/dev")

      added = Path.join(root, "lib/added.ex")
      write_file!(added, "fixture")
      updated = Paths.for_project(project, fn ^project -> {:ok, info} end)
      assert Enum.sort(updated.source_paths) == Enum.sort([source, added])
    end

    @tag :tmp_dir
    test "bare discovery needs no engine configuration", %{tmp_dir: root} do
      source = Path.join(root, "deps/source.ex")
      write_file!(source, "defmodule BareDependency, do: :ok")
      project = root |> Forge.Document.Path.to_uri() |> Project.bare()
      paths = Paths.for_project(project, fn _ -> flunk("Bare discovery must be local") end)
      assert paths.source_paths == [source]
      assert paths.beam_paths == []
    end

    @tag :tmp_dir
    test "does not include project-local default build files", %{tmp_dir: tmp_dir} do
      with_env("MIX_BUILD_PATH", native_join([tmp_dir, ".expert", "build", "dev"]))

      source_file = native_join([tmp_dir, "lib", "source_file.ex"])
      build_file = mix_build_file!(tmp_dir, "generated.ex")

      write_mix_project!(
        tmp_dir,
        "DefaultBuildPathIndexerTest.MixProject",
        ~s([app: :default_build_path_indexer_test, version: "0.1.0"])
      )

      write_file!(source_file, "defmodule SourceFile do end")
      write_file!(build_file, "defmodule GeneratedBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      assert source_file in source_paths(project)
      refute build_file in source_paths(project)
    end

    @tag :tmp_dir
    test "does not include files under a configured build path", %{tmp_dir: tmp_dir} do
      with_env("MIX_BUILD_PATH", native_join([tmp_dir, ".expert", "build", "dev"]))

      source_file = native_join([tmp_dir, "lib", "source_file.ex"])
      build_file = mix_build_file!(tmp_dir, "generated.ex", build_path: "custom_build")

      write_mix_project!(
        tmp_dir,
        "ConfiguredBuildPathIndexerTest.MixProject",
        ~s([app: :configured_build_path_indexer_test, version: "0.1.0", build_path: "custom_build"])
      )

      write_file!(source_file, "defmodule SourceFile do end")
      write_file!(build_file, "defmodule GeneratedBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      assert source_file in source_paths(project)
      refute build_file in source_paths(project)
    end

    @tag :tmp_dir
    test "does not include files under MIX_BUILD_ROOT", %{tmp_dir: tmp_dir} do
      build_root = native_join([tmp_dir, "custom_build_root"])
      with_env("MIX_BUILD_ROOT", build_root)
      with_env("MIX_BUILD_PATH", native_join([tmp_dir, ".expert", "build", "dev"]))

      source_file = native_join([tmp_dir, "lib", "source_file.ex"])
      build_file = native_join([build_root, "generated.ex"])

      write_mix_project!(
        tmp_dir,
        "MixBuildRootIndexerTest.MixProject",
        ~s([app: :mix_build_root_indexer_test, version: "0.1.0"])
      )

      write_file!(source_file, "defmodule SourceFile do end")
      write_file!(build_file, "defmodule GeneratedBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      assert source_file in source_paths(project)
      refute build_file in source_paths(project)
    end

    @tag :tmp_dir
    test "does not include active path dependency source files", %{tmp_dir: tmp_dir} do
      app_root = native_join([tmp_dir, "app"])
      dep_root = native_join([tmp_dir, "dep"])
      app_file = native_join([app_root, "lib", "app_module.ex"])
      dep_file = native_join([dep_root, "lib", "dep_module.ex"])

      write_mix_project!(
        app_root,
        "PathDependencyPathsTest.MixProject",
        ~s([app: :path_dependency_paths_test, version: "0.1.0", deps: [{:dep, path: "../dep"}]])
      )

      write_mix_project!(
        dep_root,
        "PathDependencyPathsTest.DepMixProject",
        ~s([app: :dep, version: "0.1.0"])
      )

      write_file!(app_file, "defmodule AppModule do end")
      write_file!(dep_file, "defmodule DepModule do end")

      project = app_root |> Forge.Document.Path.to_uri() |> Project.new()

      patch(EngineApi, :project_configuration, fn ^project, configured_project ->
        Engine.Mix.project_configuration(configured_project)
      end)

      assert app_file in source_paths(project)
      refute dep_file in source_paths(project)
    end
  end

  defp with_env(name, value) do
    original = System.fetch_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      case original do
        {:ok, value} -> System.put_env(name, value)
        :error -> System.delete_env(name)
      end
    end)
  end

  defp write_file!(path, contents) do
    path = Forge.Path.native(path)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp native_join(path_segments) do
    path_segments
    |> Path.join()
    |> Forge.Path.native()
  end

  defp write_mix_project!(root, module_name, project_config) do
    write_file!(Path.join(root, "mix.exs"), """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        #{project_config}
      end
    end
    """)
  end

  defp mix_build_file!(root, relative_path, config \\ []) do
    build_root =
      File.cd!(root, fn ->
        config
        |> Keyword.put_new(:build_per_environment, true)
        |> Mix.Project.build_path()
        |> Path.dirname()
      end)

    [build_root | List.wrap(relative_path)]
    |> Path.join()
    |> Forge.Path.native()
  end
end
