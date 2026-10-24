defmodule Expert.Namespace.Transform.Boots do
  @moduledoc """
  A transformer that re-builds .boot files by converting a .script file
  """
  def apply_to_all(base_directory) do
    base_directory
    |> find_boot_files()
    |> tap(fn boot_files ->
      Mix.Shell.IO.info("Rebuilding #{length(boot_files)} boot files")
    end)
    |> Enum.each(&apply/1)
  end

  def apply(file_path) do
    file_path
    |> Path.rootname()
    |> String.to_charlist()
    |> :systools.script2boot()
  end

  defp find_boot_files(base_directory) do
    base_directory = Forge.OS.normalize_path(base_directory)

    [base_directory, "**", "*.script"]
    |> Path.join()
    |> Path.wildcard()
  end
end
