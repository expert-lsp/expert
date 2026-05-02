defmodule Engine.Search.IndexerTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Engine.Dispatch
  alias Engine.Search.Indexer
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defmodule FakeBackend do
    def set_entries(entries) when is_list(entries) do
      :persistent_term.put({__MODULE__, :entries}, entries)
    end

    def reduce(accumulator, reducer_fun) do
      {__MODULE__, :entries}
      |> :persistent_term.get([])
      |> Enum.reduce(accumulator, fn
        %{id: id} = entry, acc when is_integer(id) -> reducer_fun.(entry, acc)
        _, acc -> acc
      end)
    end
  end

  setup do
    project = project()
    start_supervised!(Engine.ApplicationCache)
    start_supervised(Dispatch)
    # Mock the broadcast so progress reporting doesn't fail
    patch(Engine.Api.Proxy, :broadcast, fn _ -> :ok end)
    # Mock erpc calls for progress reporting
    patch(Dispatch, :erpc_call, fn
      Expert.Progress, :begin, [_title, _opts] ->
        {:ok, System.unique_integer([:positive])}

      Expert.Progress, :report, _args ->
        :ok
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)
    {:ok, project: project}
  end

  defp with_env(name, value) do
    original = System.fetch_env(name)
    System.put_env(name, value)

    on_exit(fn -> restore_env(name, original) end)
  end

  defp restore_env(name, {:ok, value}), do: System.put_env(name, value)
  defp restore_env(name, :error), do: System.delete_env(name)

  describe "create_index/1" do
    test "returns a list of entries", %{project: project} do
      assert {:ok, entry_stream} = Indexer.create_index(project)
      entries = Enum.to_list(entry_stream)
      project_root = Project.root_path(project)

      assert not Enum.empty?(entries)
      assert Enum.all?(entries, fn entry -> String.starts_with?(entry.path, project_root) end)
    end

    test "entries are either .ex or .exs files", %{project: project} do
      assert {:ok, entries} = Indexer.create_index(project)
      assert Enum.all?(entries, fn entry -> Path.extname(entry.path) in [".ex", ".exs"] end)
    end

    test "indexes bare projects without treating root/deps as a dependency directory" do
      bare_root = Path.join(fixtures_path(), "scratch")
      bare_project = bare_root |> Forge.Document.Path.to_uri() |> Project.bare()

      patch(Engine, :get_project, fn -> bare_project end)

      assert {:ok, entries} = Indexer.create_index(bare_project)
      assert Enum.any?(entries, &(&1.path == Path.join(bare_root, "bare_file.ex")))
    end

    test "does not index project-local _build files", %{project: project} do
      with_env(
        "MIX_BUILD_PATH",
        Path.join([Project.root_path(project), ".expert", "build", "dev"])
      )

      build_file = Path.join([Project.root_path(project), "_build", "generated.ex"])

      File.mkdir_p!(Path.dirname(build_file))
      File.write!(build_file, "defmodule GeneratedBuildFile do end")

      on_exit(fn -> File.rm_rf(Path.dirname(build_file)) end)

      refute build_file in Indexer.indexable_files(project)
    end

    @tag :tmp_dir
    test "does not index files under a configured build path", %{tmp_dir: tmp_dir} do
      with_env("MIX_BUILD_PATH", Path.join([tmp_dir, ".expert", "build", "dev"]))

      source_file = Path.join([tmp_dir, "lib", "source_file.ex"])
      build_file = Path.join([tmp_dir, "custom_build", "dev", "generated.ex"])

      File.mkdir_p!(Path.dirname(source_file))
      File.mkdir_p!(Path.dirname(build_file))

      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule ConfiguredBuildPathIndexerTest.MixProject do
        use Mix.Project

        def project do
          [app: :configured_build_path_indexer_test, version: "0.1.0", build_path: "custom_build"]
        end
      end
      """)

      File.write!(source_file, "defmodule SourceFile do end")
      File.write!(build_file, "defmodule GeneratedBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      assert source_file in Indexer.indexable_files(project)
      refute build_file in Indexer.indexable_files(project)
    end

    @tag :tmp_dir
    test "does not index files under MIX_BUILD_ROOT", %{tmp_dir: tmp_dir} do
      build_root = Path.join(tmp_dir, "custom_build_root")
      with_env("MIX_BUILD_ROOT", build_root)
      with_env("MIX_BUILD_PATH", Path.join([tmp_dir, ".expert", "build", "dev"]))

      source_file = Path.join([tmp_dir, "lib", "source_file.ex"])
      build_file = Path.join([build_root, "dev", "generated.ex"])

      File.mkdir_p!(Path.dirname(source_file))
      File.mkdir_p!(Path.dirname(build_file))

      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule MixBuildRootIndexerTest.MixProject do
        use Mix.Project

        def project do
          [app: :mix_build_root_indexer_test, version: "0.1.0"]
        end
      end
      """)

      File.write!(source_file, "defmodule SourceFile do end")
      File.write!(build_file, "defmodule GeneratedBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      assert source_file in Indexer.indexable_files(project)
      refute build_file in Indexer.indexable_files(project)
    end

    @tag :tmp_dir
    test "indexes active path dependency sources", %{tmp_dir: tmp_dir} do
      app_root = Path.join(tmp_dir, "app")
      dep_root = Path.join(tmp_dir, "dep")
      app_file = Path.join([app_root, "lib", "app_module.ex"])
      dep_file = Path.join([dep_root, "lib", "dep_module.ex"])
      dep_build_file = Path.join([dep_root, "_build", "generated.ex"])

      File.mkdir_p!(Path.dirname(app_file))
      File.mkdir_p!(Path.dirname(dep_file))
      File.mkdir_p!(Path.dirname(dep_build_file))

      File.write!(Path.join(app_root, "mix.exs"), """
      defmodule PathDependencyIndexerTest.MixProject do
        use Mix.Project

        def project do
          [app: :path_dependency_indexer_test, version: "0.1.0", deps: [{:dep, path: "../dep"}]]
        end
      end
      """)

      File.write!(app_file, "defmodule AppModule do end")
      File.write!(dep_file, "defmodule DepModule do end")
      File.write!(dep_build_file, "defmodule GeneratedDependencyBuildFile do end")

      project = app_root |> Forge.Document.Path.to_uri() |> Project.new()

      assert dep_file in Indexer.indexable_files(project)
      refute dep_build_file in Indexer.indexable_files(project)

      assert {:ok, entries} = Indexer.create_index(project)
      assert Enum.any?(entries, &(&1.subject == DepModule and &1.subtype == :definition))
      refute Enum.any?(entries, &(&1.subject == GeneratedDependencyBuildFile))
    end
  end

  @ephemeral_file_name "ephemeral.ex"

  def with_an_ephemeral_file(%{project: project}, file_contents) do
    file_path = Path.join([Project.root_path(project), "lib", @ephemeral_file_name])
    File.write!(file_path, file_contents)

    on_exit(fn ->
      File.rm(file_path)
    end)

    {:ok, file_path: file_path}
  end

  def with_a_file_with_a_module(context) do
    file_contents = ~s[
        defmodule Ephemeral do
        end
      ]
    with_an_ephemeral_file(context, file_contents)
  end

  def with_an_existing_index(%{project: project}) do
    {:ok, entry_stream} = Indexer.create_index(project)
    entries = Enum.to_list(entry_stream)
    FakeBackend.set_entries(entries)
    {:ok, entries: entries}
  end

  describe "update_index/2 encounters a new file" do
    setup [:with_an_existing_index, :with_a_file_with_a_module]

    test "the ephemeral file is not previously present in the index", %{entries: entries} do
      refute Enum.any?(entries, fn entry -> Path.basename(entry.path) == @ephemeral_file_name end)
    end

    test "the ephemeral file is listed in the updated index", %{project: project} do
      {:ok, entry_stream, []} = Indexer.update_index(project, FakeBackend)
      assert [_structure, updated_entry] = Enum.to_list(entry_stream)
      assert Path.basename(updated_entry.path) == @ephemeral_file_name
      assert updated_entry.subject == Ephemeral
    end
  end

  def with_an_ephemeral_empty_file(context) do
    with_an_ephemeral_file(context, "")
  end

  describe "update_index/2 encounters a zero-length file" do
    setup [:with_an_existing_index, :with_an_ephemeral_empty_file]

    test "and does nothing", %{project: project} do
      {:ok, entry_stream, []} = Indexer.update_index(project, FakeBackend)
      assert [] = Enum.to_list(entry_stream)
    end

    test "there is no progress", %{project: project} do
      # this ensures we don't emit progress with a total byte size of 0, which will
      # cause an ArithmeticError

      Dispatch.register_listener(self(), :all)
      {:ok, entry_stream, []} = Indexer.update_index(project, FakeBackend)
      assert [] = Enum.to_list(entry_stream)
      refute_receive _
    end
  end

  describe "update_index/2" do
    setup [:with_a_file_with_a_module, :with_an_existing_index]

    test "sees the ephemeral file", %{entries: entries} do
      assert Enum.any?(entries, fn entry -> Path.basename(entry.path) == @ephemeral_file_name end)
    end

    test "returns the file paths of deleted files", %{project: project, file_path: file_path} do
      File.rm(file_path)
      assert {:ok, entry_stream, [^file_path]} = Indexer.update_index(project, FakeBackend)
      assert [] = Enum.to_list(entry_stream)
    end

    test "updates files that have changed since the last index", %{
      project: project,
      entries: entries,
      file_path: file_path
    } do
      entries = Enum.reject(entries, &is_nil(&1.id))
      path_to_mtime = Map.new(entries, fn entry -> {entry.path, Entry.updated_at(entry)} end)

      [entry | _] = entries
      {{year, month, day}, hms} = Entry.updated_at(entry)
      old_mtime = {{year - 1, month, day}, hms}

      patch(Indexer, :stat, fn path ->
        {ymd, {hour, minute, second}} =
          Map.get_lazy(path_to_mtime, file_path, &:calendar.universal_time/0)

        mtime =
          if path == file_path do
            {ymd, {hour, minute, second + 1}}
          else
            old_mtime
          end

        {:ok, %File.Stat{mtime: mtime}}
      end)

      new_contents = ~s[
        defmodule Brand.Spanking.New do
        end
      ]

      File.write!(file_path, new_contents)

      assert {:ok, entry_stream, []} = Indexer.update_index(project, FakeBackend)
      assert [_structure, entry] = Enum.to_list(entry_stream)
      assert entry.path == file_path
      assert entry.subject == Brand.Spanking.New
    end
  end
end
