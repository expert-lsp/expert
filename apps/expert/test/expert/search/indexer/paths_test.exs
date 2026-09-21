defmodule Expert.Search.Indexer.PathsTest do
  use ExUnit.Case, async: false

  alias Expert.Search.Indexer.Paths
  alias Forge.Project

  describe "indexable_files/1" do
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

      assert source_file in Paths.indexable_files(project)
      refute build_file in Paths.indexable_files(project)
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

      assert source_file in Paths.indexable_files(project)
      refute build_file in Paths.indexable_files(project)
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

      assert source_file in Paths.indexable_files(project)
      refute build_file in Paths.indexable_files(project)
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

      assert app_file in Paths.indexable_files(project)
      refute dep_file in Paths.indexable_files(project)
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
