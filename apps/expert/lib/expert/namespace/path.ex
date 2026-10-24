defmodule Expert.Namespace.Path do
  alias Expert.Namespace.Module, as: NamespaceModule

  def apply(path) when is_list(path) do
    path
    |> List.to_string()
    |> apply()
    |> String.to_charlist()
  end

  def apply(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.map(&replace_namespaced_apps/1)
    |> Path.join()
  end

  defp replace_namespaced_apps(path_component) do
    Enum.reduce(Mix.Tasks.Namespace.app_names(), path_component, fn app_name, path ->
      [path | vsn] = String.split(path, "-")

      if path == Atom.to_string(app_name) do
        new_path =
          app_name
          |> NamespaceModule.apply()
          |> Atom.to_string()

        rebuild_path(new_path, vsn)
      else
        rebuild_path(path, vsn)
      end
    end)
  end

  defp rebuild_path(path, []), do: path

  defp rebuild_path(path, rest) do
    "#{path}-#{Enum.join(rest, "-")}"
  end
end
