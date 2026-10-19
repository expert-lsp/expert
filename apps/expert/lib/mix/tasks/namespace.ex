defmodule Mix.Tasks.Namespace do
  @moduledoc """
  This task is used after a release is assembled, and investigates the engine
  app for its dependencies, at which point it applies transformers to various parts of the
  app.

  Transformers take a path, find their relevant files and apply transforms to them. For example,
  the Beams transformer will find any instances of modules in .beam files, and will apply namespaces
  to them if the module is one of the modules defined in a dependency.

  This task takes a single argument, which is the full path to the release.
  """
  use Mix.Task

  alias Expert.Namespace.FileSync, as: NamespaceFileSync
  alias Expert.Namespace.Transform, as: NamespaceTransform
  alias Forge.Ast

  @excluded_apps [:patch, :burrito, :exqlite, :db_connection, :elixir_make, :cc_precompiler]
  # Unless explicitly added, nimble_parsec won't show up as a loaded app
  # and will therefore not be namespaced.
  @no_app_deps [:nimble_parsec]

  # These app names and root modules are strings to avoid them being namespaced
  # by this task.
  @extra_apps %{
    "engine" => "Engine",
    "expert" => "Expert",
    "forge" => "Forge"
  }

  def run([base_directory, output_directory | opts]) do
    {args, _, _} =
      OptionParser.parse(opts,
        strict: [cwd: :string, no_progress: :boolean]
      )

    cwd = Keyword.get(args, :cwd, File.cwd!())
    no_progress = Keyword.get(args, :no_progress, false)

    :persistent_term.put(:forge_namespace_cwd, cwd)

    # Ensure we cache the loaded apps at the time of namespacing
    # Otherwise only the @extra_apps will be cached
    init()

    File.mkdir_p!(output_directory)

    opts = [no_progress: no_progress]

    if base_directory == output_directory do
      apply_transforms(base_directory, opts)
    else
      incremental_transforms(base_directory, output_directory, opts)
    end
  end

  defp apply_transforms(directory, opts) do
    NamespaceTransform.Apps.apply_to_all(directory)
    NamespaceTransform.Beams.apply_to_all(directory, opts)
    NamespaceTransform.Scripts.apply_to_all(directory)
    # The boot file transform just turns script files into boot files
    # so it must come after the script file transform
    NamespaceTransform.Boots.apply_to_all(directory)
    NamespaceTransform.Configs.apply_to_all(directory)
    NamespaceTransform.AppDirectories.apply_to_all(directory)
  end

  defp incremental_transforms(base_directory, output_directory, opts) do
    Application.ensure_all_started(:briefly)

    classification =
      NamespaceFileSync.classify_files(base_directory, output_directory)

    tmp_dir = Briefly.create!(directory: true)

    entries_to_namespace =
      classification.new ++ classification.changed

    Mix.Shell.IO.info("""
    Namespacing #{length(entries_to_namespace)} files:
      New: #{length(classification.new)}
      Changed: #{length(classification.changed)}
      Deleted: #{length(classification.deleted)}
    """)

    NamespaceFileSync.copy_new_and_changed(classification, base_directory, tmp_dir)
    NamespaceFileSync.delete_removed(classification)

    # Apply transforms to temp directory
    apply_transforms(tmp_dir, opts)

    # Copy temp directory back to output directory
    File.cp_r!(tmp_dir, output_directory)
  end

  def app_names do
    Map.keys(app_to_root_modules())
  end

  def root_modules do
    app_to_root_modules()
    |> Map.values()
    |> List.flatten()
  end

  def app_to_root_modules do
    case :persistent_term.get(__MODULE__, :not_loaded) do
      :not_loaded ->
        init()

      term ->
        term
    end
  end

  defp register_mappings(app_to_root_modules) do
    :persistent_term.put(__MODULE__, app_to_root_modules)
    app_to_root_modules
  end

  defp root_modules_for_apps(deps_apps) do
    deps_apps
    |> Enum.map(fn app_name ->
      all_modules = app_modules(app_name)

      case Enum.filter(all_modules, fn module -> length(safe_split_module(module)) == 1 end) do
        [] -> {app_name, [Expert]}
        root_modules -> {app_name, root_modules}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp app_modules(dep_app) do
    Application.ensure_loaded(dep_app)

    case :application.get_key(dep_app, :modules) do
      {:ok, modules} ->
        modules

      _ ->
        [Expert]
    end
  end

  defp safe_split_module(module) do
    case Ast.Module.safe_split(module) do
      {:elixir, segments} -> segments
      {:erlang, _} -> []
    end
  end

  defp extra_apps do
    Map.new(@extra_apps, fn {k, v} ->
      root_module =
        v
        |> List.wrap()
        |> Module.concat()

      {String.to_atom(k), [root_module]}
    end)
  end

  defp init do
    discover_deps_apps()
    |> Enum.concat(@no_app_deps)
    |> Kernel.--(@excluded_apps)
    |> root_modules_for_apps()
    |> Map.merge(extra_apps())
    |> register_mappings()
  end

  defp discover_deps_apps do
    cwd = :persistent_term.get(:forge_namespace_cwd, File.cwd!())

    :application.loaded_applications()
    |> Enum.flat_map(fn {app_name, _description, _version} ->
      try do
        app_dir = Application.app_dir(app_name)

        if String.starts_with?(app_dir, cwd) do
          [app_name]
        else
          []
        end
      rescue
        _ -> []
      end
    end)
    |> Enum.sort()
  end
end
