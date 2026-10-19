defmodule Expert.Namespace.FileSync do
  alias __MODULE__.Classification
  alias Expert.Namespace.Module, as: NamespaceModule
  alias Expert.Namespace.Path, as: NamespacePath

  defmodule Classification do
    defstruct changed: [],
              new: [],
              deleted: []
  end

  @type classification :: %Classification{
          changed: list({String.t(), String.t()}),
          new: list({String.t(), String.t()}),
          deleted: list(String.t())
        }

  @doc """
  Classifies files into changed, new, and deleted categories.

  It looks at files in both the base directory and output directory,
  applying namespacing to the file names in the output directory.

  Then compares the mtimes of the files to determine their classification.

  If files in output_directory are not present in base_directory, they are classified as deleted.
  """
  def classify_files(same, same),
    do: %Classification{
      changed: [],
      new: [],
      deleted: []
    }

  def classify_files(base_directory, output_directory) do
    base_files = find_files(Path.join(base_directory, "lib"))
    output_files = find_files(Path.join(output_directory, "lib"))

    base_map =
      Enum.reduce(base_files, %{}, fn base_file, acc ->
        relative_path = Path.relative_to(base_file, base_directory)

        namespaced_relative_path =
          relative_path
          |> NamespacePath.apply()
          |> maybe_namespace_filename()

        dest_path = Path.join(output_directory, namespaced_relative_path)
        Map.put(acc, base_file, dest_path)
      end)

    expected_dest_files = base_map |> Map.values() |> MapSet.new()
    output_set = MapSet.new(output_files)

    classification =
      Enum.reduce(base_map, %Classification{}, fn {base_file, dest_path}, acc ->
        if File.exists?(dest_path) do
          base_mtime = File.stat!(base_file).mtime
          output_mtime = File.stat!(dest_path).mtime

          if base_mtime > output_mtime do
            %{acc | changed: [{base_file, dest_path} | acc.changed]}
          else
            acc
          end
        else
          %{acc | new: [{base_file, dest_path} | acc.new]}
        end
      end)

    deleted_files =
      output_set
      |> MapSet.difference(MapSet.new(expected_dest_files))
      |> MapSet.to_list()

    %{classification | deleted: deleted_files}
  end

  @doc """
  Copy new and changed files into a destination root (e.g., tmp dir) while
  preserving relative paths and namespacing.
  """
  def copy_new_and_changed(%Classification{} = classification, base_directory, destination_root) do
    Enum.each(classification.new ++ classification.changed, fn {src, _dest} ->
      relative_path = Path.relative_to(src, base_directory)
      destination_path = Path.join(destination_root, relative_path)

      File.mkdir_p!(Path.dirname(destination_path))
      File.cp!(src, destination_path)
    end)

    :ok
  end

  @doc """
  Delete files listed in the classification from the given root.
  """
  def delete_removed(%Classification{} = classification) do
    Enum.each(classification.deleted, fn dest ->
      if File.exists?(dest) do
        File.rm!(dest)
      end
    end)

    :ok
  end

  defp find_files(directory) do
    directory = Forge.OS.normalize_path(directory)

    [directory, "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp maybe_namespace_filename(file_path) do
    # namespace filename for .beam and .app files
    extname = Path.extname(file_path)

    if extname in [".beam", ".app"] do
      dirname = Path.dirname(file_path)
      basename = Path.basename(file_path, extname)

      namespaced_basename =
        basename
        |> String.to_atom()
        |> NamespaceModule.apply()
        |> Atom.to_string()

      Path.join(dirname, namespaced_basename <> extname)
    else
      file_path
    end
  end
end
