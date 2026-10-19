defmodule Expert.Namespace.FileSyncTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.Namespace.FileSync
  alias Expert.Namespace.FileSync.Classification

  @moduletag tmp_dir: true

  setup do
    patch(Mix.Tasks.Namespace, :app_to_root_modules, %{
      foo: [Foo],
      forge: [Forge]
    })

    :ok
  end

  describe "classify_files/2" do
    test "returns empty classification when directories match", %{tmp_dir: tmp_dir} do
      assert %Classification{changed: [], new: [], deleted: []} =
               FileSync.classify_files(tmp_dir, tmp_dir)
    end

    test "marks base-only files as new with namespacing", %{tmp_dir: tmp_dir} do
      {base_dir, output_dir} = dirs(tmp_dir)

      base_files = [
        write_file(Path.join(base_dir, "lib/foo/ebin/Elixir.Foo.beam")),
        write_file(Path.join(base_dir, "lib/foo/ebin/foo.app")),
        write_file(Path.join(base_dir, "lib/foo/ebin/erl_module.beam"))
      ]

      classification = FileSync.classify_files(base_dir, output_dir)

      expected_new =
        [
          {Enum.at(base_files, 0), Path.join(output_dir, "lib/xp_foo/ebin/Elixir.XPFoo.beam")},
          {Enum.at(base_files, 1), Path.join(output_dir, "lib/xp_foo/ebin/xp_foo.app")},
          {Enum.at(base_files, 2), Path.join(output_dir, "lib/xp_foo/ebin/erl_module.beam")}
        ]
        |> MapSet.new()

      assert %Classification{new: new, changed: [], deleted: []} = classification
      assert MapSet.new(new) == expected_new
    end

    test "marks older output files as changed", %{tmp_dir: tmp_dir} do
      {base_dir, output_dir} = dirs(tmp_dir)

      base_files = [
        write_file(Path.join(base_dir, "lib/foo/ebin/Elixir.Foo.beam")),
        write_file(Path.join(base_dir, "lib/foo/ebin/foo.app")),
        write_file(Path.join(base_dir, "lib/foo/ebin/erl_module.beam"))
      ]

      dest_changed = Path.join(output_dir, "lib/xp_foo/ebin/Elixir.XPFoo.beam")
      dest_new = Path.join(output_dir, "lib/xp_foo/ebin/xp_foo.app")
      dest_erl = Path.join(output_dir, "lib/xp_foo/ebin/erl_module.beam")

      write_file(dest_changed)
      write_file(dest_new)
      write_file(dest_erl)

      older = {{2020, 1, 1}, {0, 0, 0}}
      newer = {{2020, 1, 1}, {0, 0, 1}}

      File.touch!(dest_changed, older)
      File.touch!(dest_new, older)
      File.touch!(dest_erl, older)

      Enum.each(base_files, &File.touch!(&1, newer))

      classification = FileSync.classify_files(base_dir, output_dir)

      expected_changed =
        [
          {Enum.at(base_files, 0), dest_changed},
          {Enum.at(base_files, 1), dest_new},
          {Enum.at(base_files, 2), dest_erl}
        ]
        |> MapSet.new()

      assert %Classification{changed: changed, new: [], deleted: []} = classification
      assert MapSet.new(changed) == expected_changed
    end

    test "marks output-only files as deleted", %{tmp_dir: tmp_dir} do
      {base_dir, output_dir} = dirs(tmp_dir)

      deleted_files = [
        "lib/releases/0.1.0/consolidated/Elixir.XPForge.Document.Container.beam",
        "lib/releases/0.1.0/runtime.exs",
        "lib/releases/0.1.0/start.boot"
      ]

      Enum.each(deleted_files, fn rel ->
        path = Path.join(output_dir, rel)
        write_file(path)
        assert File.regular?(path)
      end)

      created_files =
        output_dir
        |> Path.join("lib/**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)

      assert length(created_files) == length(deleted_files)

      classification = FileSync.classify_files(base_dir, output_dir)

      assert %Classification{deleted: deleted, new: [], changed: []} = classification

      assert MapSet.new(deleted) ==
               deleted_files
               |> MapSet.new(&Path.join(output_dir, &1))
    end

    test "handles mixed new, changed, and deleted entries", %{tmp_dir: tmp_dir} do
      {base_dir, output_dir} = dirs(tmp_dir)

      base_new = write_file(Path.join(base_dir, "lib/foo/ebin/foo.app"))
      base_changed = write_file(Path.join(base_dir, "lib/foo/ebin/Elixir.Foo.beam"))

      dest_changed = Path.join(output_dir, "lib/xp_foo/ebin/Elixir.XPFoo.beam")
      write_file(dest_changed)

      older = {{2020, 1, 1}, {0, 0, 0}}
      newer = {{2020, 1, 1}, {0, 0, 1}}

      File.touch!(dest_changed, older)
      File.touch!(base_changed, newer)

      deleted_files = [
        "lib/releases/0.1.0/consolidated/Elixir.XPForge.Document.Container.beam",
        "lib/releases/0.1.0/runtime.exs"
      ]

      Enum.each(deleted_files, fn rel ->
        path = Path.join(output_dir, rel)
        write_file(path)
        assert File.regular?(path)
      end)

      File.touch!(base_new, newer)

      classification = FileSync.classify_files(base_dir, output_dir)

      expected_new =
        [{base_new, Path.join(output_dir, "lib/xp_foo/ebin/xp_foo.app")}]
        |> MapSet.new()

      expected_changed =
        [{base_changed, dest_changed}]
        |> MapSet.new()

      expected_deleted =
        deleted_files
        |> MapSet.new(&Path.join(output_dir, &1))

      assert %Classification{new: new, changed: changed, deleted: deleted} = classification

      assert MapSet.new(new) == expected_new
      assert MapSet.new(changed) == expected_changed
      assert MapSet.new(deleted) == expected_deleted
    end
  end

  defp dirs(tmp_dir) do
    base_dir = Path.join(tmp_dir, "base")
    output_dir = Path.join(tmp_dir, "output")
    File.mkdir_p!(base_dir)
    File.mkdir_p!(output_dir)
    {base_dir, output_dir}
  end

  defp write_file(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end
end
