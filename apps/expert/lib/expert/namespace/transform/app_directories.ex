defmodule Expert.Namespace.Transform.AppDirectories do
  alias Expert.Namespace.Path, as: NamespacePath

  def apply_to_all(base_directory) do
    base_directory
    |> find_app_directories()
    |> Enum.each(&apply_transform(base_directory, &1))
  end

  def apply_transform(base_directory, app_path) do
    namespaced_relative_path =
      app_path
      |> Path.relative_to(base_directory)
      |> NamespacePath.apply()

    namespaced_app_path = Path.join(base_directory, namespaced_relative_path)

    with {:ok, _} <- File.rm_rf(namespaced_app_path) do
      File.rename!(app_path, namespaced_app_path)
    end
  catch
    e ->
      Mix.Shell.IO.error("Failed to rename app directory")
      reraise e, __STACKTRACE__
  end

  defp find_app_directories(base_directory) do
    base_directory = Forge.OS.normalize_path(base_directory)
    app_names = Mix.Tasks.Namespace.app_names()
    app_globs = Enum.join(app_names, "*,")

    [base_directory, "lib", "{" <> app_globs <> "*}"]
    |> Path.join()
    |> Path.wildcard()
  end
end
