defmodule Expert.Search.Indexer.ManifestTest do
  use ExUnit.Case, async: true

  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Manifest.Entry
  alias Expert.Search.Indexer.Paths

  @moduletag :tmp_dir

  describe "plan/2" do
    test "does not fan out from one new beam to all known beams", %{tmp_dir: tmp_dir} do
      beam_paths =
        [known_beam_1, known_beam_2, known_beam_3, new_beam_path] = beam_paths(tmp_dir, 4)

      Enum.each(beam_paths, &File.write!(&1, "beam"))

      manifest_entries =
        [known_beam_1, known_beam_2, known_beam_3]
        |> Enum.map(fn beam_path ->
          assert {:ok, entry} = Entry.skipped_beam(beam_path, nil)
          entry
        end)

      manifest = Manifest.new(manifest_entries)
      paths = %Paths{source_paths: [], beam_paths: beam_paths}

      assert %Manifest.Plan{beam_paths_to_index: [^new_beam_path]} =
               Manifest.plan(manifest, paths)
    end

    test "clears every output when a beam disappears", %{tmp_dir: tmp_dir} do
      [beam_path] = beam_paths(tmp_dir, 1)
      source_path = Path.join(tmp_dir, "source.ex")
      generated_path = Path.join(tmp_dir, "generated.ex")
      File.write!(beam_path, "beam")
      File.write!(source_path, "source")
      File.write!(generated_path, "generated")

      assert {:ok, entry} = Entry.beam(beam_path, source_path)
      entry = Entry.put_output_paths(entry, [source_path, generated_path])
      manifest = Manifest.new([entry])

      File.rm!(beam_path)

      assert %Manifest.Plan{
               input_paths_to_remove: [^beam_path],
               output_paths_to_clear: outputs
             } = Manifest.plan(manifest, %Paths{source_paths: [], beam_paths: []})

      assert MapSet.new(outputs) == MapSet.new([source_path, generated_path])
    end
  end

  defp beam_paths(tmp_dir, count) do
    root = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(root)

    for index <- 1..count do
      Path.join(root, "dep#{index}.beam")
    end
  end
end
