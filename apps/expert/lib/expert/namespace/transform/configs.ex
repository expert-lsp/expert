defmodule Expert.Namespace.Transform.Configs do
  alias Expert.Namespace.Module, as: NamespaceModule

  def apply_to_all(base_directory) do
    base_directory = Forge.OS.normalize_path(base_directory)

    base_directory
    |> Path.join("**/runtime.exs")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.absname/1)
    |> tap(fn paths ->
      Mix.Shell.IO.info("Rewriting #{length(paths)} config scripts.")
    end)
    |> Enum.each(&apply/1)
  end

  def apply(path) do
    namespaced =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.postwalk(fn
        {:__aliases__, meta, alias} ->
          namespaced_alias =
            alias
            |> Module.concat()
            |> NamespaceModule.apply()
            |> Module.split()
            |> Enum.map(&String.to_atom/1)

          {:__aliases__, meta, namespaced_alias}

        atom when is_atom(atom) ->
          NamespaceModule.apply(atom)

        ast ->
          ast
      end)
      |> Macro.to_string()

    File.write!(path, namespaced)
  end
end
