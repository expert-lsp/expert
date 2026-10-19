defmodule Expert.Namespace.Transform.Scripts do
  @moduledoc """
  A transform that updates any module in .script and .rel files with namespaced versions
  """

  alias Expert.Namespace.Erlang, as: NamespaceErlang
  alias Expert.Namespace.Module, as: NamespaceModule
  alias Expert.Namespace.Path, as: NamespacePath

  def apply_to_all(base_directory) do
    base_directory
    |> find_scripts()
    |> tap(fn script_files ->
      Mix.Shell.IO.info("Rewriting #{length(script_files)} scripts")
    end)
    |> Enum.each(&apply/1)
  end

  def apply(file_path) do
    with {:ok, app_definition} <- NamespaceErlang.path_to_term(file_path),
         {:ok, converted} <- convert(app_definition) do
      File.write(file_path, converted)
    end
  end

  @script_names ~w(start.script start_clean.script expert.rel)
  defp find_scripts(base_directory) do
    base_directory = Forge.OS.normalize_path(base_directory)
    scripts_glob = "{" <> Enum.join(@script_names, ",") <> "}"

    [base_directory, "releases", "**", scripts_glob]
    |> Path.join()
    |> Path.wildcard()
  end

  defp convert(app_definition) do
    converted = visit(app_definition)
    erlang_terms = NamespaceErlang.term_to_string(converted)

    script = """
    %% coding: utf-8
    #{erlang_terms}
    """

    {:ok, script}
  end

  # for .rel files
  defp visit({:release, release_vsn, erts_vsn, app_versions}) do
    fixed_apps =
      Enum.map(app_versions, fn {app_name, version, start_type} ->
        {NamespaceModule.apply(app_name), version, start_type}
      end)

    {:release, release_vsn, erts_vsn, fixed_apps}
  end

  defp visit({:script, script_vsn, keys}) do
    {:script, script_vsn, Enum.map(keys, &visit/1)}
  end

  defp visit({:primLoad, app_list}) do
    {:primLoad, Enum.map(app_list, &NamespaceModule.apply/1)}
  end

  defp visit({:path, paths}) do
    {:path, Enum.map(paths, &NamespacePath.apply/1)}
  end

  defp visit({:apply, {:application, :load, load_apps}}) do
    {:apply, {:application, :load, Enum.map(load_apps, &visit/1)}}
  end

  defp visit({:apply, {:application, :start_boot, apps_to_start}}) do
    {:apply, {:application, :start_boot, Enum.map(apps_to_start, &NamespaceModule.apply/1)}}
  end

  defp visit({:application, app_name, app_keys}) do
    {:application, NamespaceModule.apply(app_name), Enum.map(app_keys, &visit/1)}
  end

  defp visit({:application, app_name}) do
    {:application, NamespaceModule.apply(app_name)}
  end

  defp visit({:mod, {module_name, args}}) do
    {:mod, {NamespaceModule.apply(module_name), Enum.map(args, &visit/1)}}
  end

  defp visit({:modules, module_list}) do
    {:modules, Enum.map(module_list, &NamespaceModule.apply/1)}
  end

  defp visit({:applications, app_names}) do
    {:applications, Enum.map(app_names, &NamespaceModule.apply/1)}
  end

  defp visit(key_value) do
    key_value
  end
end
