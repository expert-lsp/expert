defmodule Expert.Search.Indexer.ManifestStoreTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Manifest.Entry, as: ManifestEntry
  alias Expert.Search.Indexer.ManifestStore
  alias Forge.Project

  @moduletag :tmp_dir

  describe "load/1" do
    test "returns missing when no manifest has been committed", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)

      assert ManifestStore.load(project) == :missing
    end

    test "returns missing for corrupt manifests", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      write_committed_manifest!(project, "not an erlang term")

      assert ManifestStore.load(project) == :missing
    end

    test "loads committed records", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      manifest = manifest(tmp_dir)

      :ok = ManifestStore.commit(project, manifest)

      assert {:ok, loaded_manifest} = ManifestStore.load(project)
      assert Manifest.entries(loaded_manifest) == Manifest.entries(manifest)
    end

    test "loads manifests with legacy backend metadata", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)

      write_committed_manifest!(
        project,
        :erlang.term_to_binary(%{
          backend: "legacy",
          schema_version: 1,
          entries: encode_entries(manifest(tmp_dir))
        })
      )

      assert {:ok, loaded_manifest} = ManifestStore.load(project)
      assert Manifest.entries(loaded_manifest) == Manifest.entries(manifest(tmp_dir))
    end

    test "loads manifests with legacy schema metadata", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)

      write_committed_manifest!(
        project,
        :erlang.term_to_binary(%{
          schema_version: 2,
          entries: encode_entries(manifest(tmp_dir))
        })
      )

      assert {:ok, loaded_manifest} = ManifestStore.load(project)
      assert Manifest.entries(loaded_manifest) == Manifest.entries(manifest(tmp_dir))
    end

    test "loads beam entries without requiring module atoms", %{
      tmp_dir: tmp_dir
    } do
      project = project(tmp_dir)
      source_path = Path.join(tmp_dir, "source.ex")
      beam_path = Path.join(tmp_dir, "Elixir.Unloaded.beam")

      write_committed_manifest!(
        project,
        :erlang.term_to_binary(%{
          entries: [
            %{
              input_path: beam_path,
              output_path: source_path,
              kind: :beam,
              mtime: {{2026, 5, 18}, {0, 0, 0}},
              size: 10
            }
          ]
        })
      )

      assert {:ok, loaded_manifest} = ManifestStore.load(project)

      assert [
               %ManifestEntry{input_path: ^beam_path, output_path: ^source_path, kind: :beam}
             ] = Manifest.entries(loaded_manifest)
    end

    test "loads legacy atom manifests written by another VM", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      source_path = Path.join(tmp_dir, "legacy.ex")

      write_legacy_manifest_from_external_vm!(project, source_path)

      assert {:ok, loaded_manifest} = ManifestStore.load(project)

      assert [
               %ManifestEntry{input_path: ^source_path, output_path: ^source_path, kind: :source}
             ] = Manifest.entries(loaded_manifest)
    end
  end

  describe "commit/2" do
    test "writes a committed manifest", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      manifest = manifest(tmp_dir, "source.ex")

      :ok = ManifestStore.commit(project, manifest)

      assert {:ok, loaded_manifest} = ManifestStore.load(project)
      assert Manifest.entries(loaded_manifest) == Manifest.entries(manifest)
    end

    test "encodes artifact kinds without persisted atoms", %{
      tmp_dir: tmp_dir
    } do
      project = project(tmp_dir)
      manifest = manifest(tmp_dir, "source.ex")

      :ok = ManifestStore.commit(project, manifest)

      assert %{
               entries: [
                 %{
                   kind: "source"
                 }
               ]
             } =
               project
               |> manifest_path()
               |> File.read!()
               |> :erlang.binary_to_term()
    end

    test "replaces the previous committed manifest", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      first_manifest = manifest(tmp_dir, "first.ex")
      second_manifest = manifest(tmp_dir, "second.ex")

      :ok = ManifestStore.commit(project, first_manifest)
      :ok = ManifestStore.commit(project, second_manifest)

      assert {:ok, loaded_manifest} = ManifestStore.load(project)
      assert Manifest.entries(loaded_manifest) == Manifest.entries(second_manifest)
    end
  end

  describe "invalidate/1" do
    test "removes the committed manifest", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)

      :ok = ManifestStore.commit(project, manifest(tmp_dir))
      :ok = ManifestStore.invalidate(project)

      assert ManifestStore.load(project) == :missing
    end

    test "returns an error when the manifest cannot be removed", %{tmp_dir: tmp_dir} do
      project = project(tmp_dir)
      :ok = ManifestStore.commit(project, manifest(tmp_dir))
      path = manifest_path(project)

      patch(File, :rm, fn ^path -> {:error, :eacces} end)

      assert {:error, :eacces} = ManifestStore.invalidate(project)
    end
  end

  defp project(tmp_dir) do
    tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()
  end

  defp manifest(tmp_dir, file_name \\ "source.ex") do
    file_path = Path.join(tmp_dir, file_name)

    Manifest.new([
      %ManifestEntry{
        input_path: file_path,
        output_path: file_path,
        kind: :source,
        mtime: {{2026, 5, 18}, {0, 0, 0}},
        size: 10
      }
    ])
  end

  defp encode_entries(%Manifest{} = manifest) do
    manifest
    |> Manifest.entries()
    |> Enum.map(fn entry ->
      %{
        input_path: entry.input_path,
        output_path: entry.output_path,
        kind: Atom.to_string(entry.kind),
        mtime: entry.mtime,
        size: entry.size,
        source_path: entry.source_path,
        source_mtime: entry.source_mtime,
        source_size: entry.source_size
      }
    end)
  end

  defp write_committed_manifest!(project, contents) do
    path = manifest_path(project)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp write_legacy_manifest_from_external_vm!(project, source_path) do
    path = manifest_path(project)

    code = """
    data = %{
      entries: [
        %{
          input_path: #{inspect(source_path)},
          output_path: #{inspect(source_path)},
          kind: :source,
          mtime: {{2026, 5, 18}, {0, 0, 0}},
          size: 10
        }
      ]
    }

    File.mkdir_p!(Path.dirname(#{inspect(path)}))
    File.write!(#{inspect(path)}, :erlang.term_to_binary(data))
    """

    script_path = Path.join(Path.dirname(path), "write_legacy_manifest.exs")
    File.mkdir_p!(Path.dirname(script_path))
    File.write!(script_path, code)

    elixir = System.find_executable("elixir") || raise "could not find elixir executable"
    {output, status} = System.cmd(elixir, [script_path], stderr_to_stdout: true)
    assert status == 0, output
  end

  defp manifest_path(project) do
    Path.join(Project.workspace_path(project, ["indexes", "manifest"]), "index_manifest.etf")
  end
end
