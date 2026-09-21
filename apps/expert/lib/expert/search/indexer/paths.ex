defmodule Expert.Search.Indexer.Paths do
  alias Forge.Project

  @indexable_extensions "*.{ex,exs}"

  defstruct source_paths: [], beam_paths: []

  @type t :: %__MODULE__{
          source_paths: [Path.t()],
          beam_paths: [Path.t()]
        }

  def for_project(%Project{} = project) do
    %__MODULE__{
      source_paths: source_paths(project),
      beam_paths: beam_paths(project)
    }
  end

  def indexable_files(%Project{} = project) do
    source_paths(project)
  end

  defp source_paths(%Project{} = project) do
    source_roots = source_index_roots(project)
    dependency_roots = dependency_roots(project)
    roots_with_build_outputs = source_roots ++ dependency_roots
    excluded_roots = dependency_roots ++ build_exclusion_roots(project, roots_with_build_outputs)

    source_roots
    |> Enum.flat_map(&indexable_files_in/1)
    |> Enum.uniq()
    |> reject_paths_under(excluded_roots)
  end

  defp indexable_files_in(root) do
    Forge.Path.glob([root, "**", @indexable_extensions])
  end

  defp source_index_roots(%Project{} = project) do
    project
    |> Project.root_path()
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reject_paths_under(paths, []), do: paths

  defp reject_paths_under(paths, roots) do
    Enum.reject(paths, &contained_in_any?(&1, roots))
  end

  defp contained_in_any?(path, roots) do
    Enum.any?(roots, &Forge.Path.contains?(path, &1))
  end

  defp beam_paths(%Project{kind: :mix} = project) do
    build_dir = build_dir(project)
    dependency_app_names = dependency_app_names(project)

    build_dir
    |> beam_app_paths()
    |> Enum.filter(fn app_path ->
      Path.basename(app_path) in dependency_app_names
    end)
    |> Enum.flat_map(&beam_files/1)
  end

  defp beam_paths(%Project{}), do: []

  @spec dependency_app_names(Project.t()) :: [String.t()]
  defp dependency_app_names(%Project{} = project) do
    (mix_dependency_app_names(project) ++ configured_dependency_app_names(project))
    |> Enum.uniq()
  end

  @spec mix_dependency_app_names(Project.t()) :: [String.t()]
  defp mix_dependency_app_names(%Project{} = project) do
    case Engine.Mix.in_project(project, fn _ ->
           Mix.Dep.clear_cached()
           Mix.Project.clear_deps_cache()
           Mix.Project.deps_apps()
         end) do
      {:ok, app_names} -> app_names |> Enum.map(&Atom.to_string/1) |> Enum.uniq()
      _ -> []
    end
  end

  @spec configured_dependency_app_names(Project.t()) :: [String.t()]
  defp configured_dependency_app_names(%Project{} = project) do
    configured_dependency_app_names(project, [])
  end

  @spec configured_dependency_app_names(Project.t(), [String.t()]) :: [String.t()]
  defp configured_dependency_app_names(%Project{} = project, seen_roots) do
    root = Project.root_path(project)

    if root in seen_roots do
      []
    else
      seen_roots = [root | seen_roots]

      case Engine.Mix.in_project(project, fn _ ->
             config = Mix.Project.config()
             env = Mix.env()
             target = Mix.target()

             {dependency_app_names(config, env, target),
              path_dependency_paths(config, env, target)}
           end) do
        {:ok, {app_names, path_roots}} ->
          Enum.reduce(path_roots, app_names, fn path_root, app_names ->
            path_root
            |> project_for_path()
            |> configured_dependency_app_names(seen_roots)
            |> Kernel.++(app_names)
            |> Enum.uniq()
          end)

        _ ->
          []
      end
    end
  end

  @spec dependency_app_names(keyword(), atom(), atom()) :: [String.t()]
  defp dependency_app_names(config, env, target) do
    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(&dependency_app_name(&1, env, target))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.uniq()
  end

  defp dependency_app_name({app, opts}, env, target) when is_atom(app) and is_list(opts) do
    dependency_app_name_from_opts(app, opts, env, target)
  end

  defp dependency_app_name({app, _requirement, opts}, env, target)
       when is_atom(app) and is_list(opts) do
    dependency_app_name_from_opts(app, opts, env, target)
  end

  defp dependency_app_name(_dep, _env, _target), do: []

  defp dependency_app_name_from_opts(app, opts, env, target) do
    app = Keyword.get(opts, :app, app)

    if app != false and is_atom(app) and dependency_active?(opts, env, target) do
      [app]
    else
      []
    end
  end

  defp dependency_roots(%Project{kind: :mix} = project) do
    [deps_path(project) | path_dependency_paths(project)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dependency_roots(%Project{}), do: []

  defp project_for_path(path) do
    path
    |> Forge.Document.Path.to_uri()
    |> Project.new()
  end

  defp deps_path(%Project{kind: :mix} = project) do
    case Engine.Mix.in_project(project, fn _ -> Mix.Project.deps_path() end) do
      {:ok, path} -> path
      _ -> Path.join(Project.root_path(project), "deps")
    end
  end

  defp path_dependency_paths(%Project{} = project) do
    case Engine.Mix.in_project(project, fn _ ->
           path_dependency_paths(Mix.Project.config(), Mix.env(), Mix.target())
         end) do
      {:ok, roots} -> roots
      _ -> []
    end
  end

  defp path_dependency_paths(config, env, target) do
    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(&path_dependency_path(&1, env, target))
  end

  defp path_dependency_path({_app, opts}, env, target) when is_list(opts) do
    path_dependency_path_from_opts(opts, env, target)
  end

  defp path_dependency_path({_app, _requirement, opts}, env, target) when is_list(opts) do
    path_dependency_path_from_opts(opts, env, target)
  end

  defp path_dependency_path(_dep, _env, _target), do: []

  defp path_dependency_path_from_opts(opts, env, target) do
    path = Keyword.get(opts, :path)

    if is_binary(path) and dependency_active?(opts, env, target) do
      [Path.expand(path, File.cwd!())]
    else
      []
    end
  end

  defp dependency_active?(opts, env, target) do
    only_envs = opts |> Keyword.get(:only) |> List.wrap()
    targets = opts |> Keyword.get(:targets) |> List.wrap()

    dependency_active_in_env?(only_envs, env) and dependency_active_for_target?(targets, target)
  end

  defp dependency_active_in_env?([], _env), do: true
  defp dependency_active_in_env?(envs, env), do: env in envs

  defp dependency_active_for_target?([], _target), do: true
  defp dependency_active_for_target?(targets, target), do: target in targets

  defp build_exclusion_roots(%Project{kind: :mix} = project, roots) do
    {runtime_build_path, configured_build_root} = build_paths(project)
    relative_build_root = Path.relative_to(configured_build_root, Project.root_path(project))

    dependency_build_roots = Enum.map(roots, &Path.expand(relative_build_root, &1))

    [runtime_build_path, configured_build_root | dependency_build_roots]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_exclusion_roots(%Project{}, _roots), do: []

  defp build_dir(%Project{kind: :mix} = project) do
    project
    |> build_paths()
    |> elem(0)
  end

  defp build_paths(%Project{kind: :mix} = project) do
    case Engine.Mix.in_project(project, fn project_module ->
           {Mix.Project.build_path(), configured_build_root(project, project_module.project())}
         end) do
      {:ok, paths} -> paths
      _ -> {source_build_dir(project), configured_build_root(project, [])}
    end
  end

  defp configured_build_root(%Project{} = project, config) do
    config = Keyword.put_new(config, :build_per_environment, true)

    with_deleted_env("MIX_BUILD_PATH", fn ->
      File.cd!(Project.root_path(project), fn ->
        config
        |> Mix.Project.build_path()
        |> Path.dirname()
      end)
    end)
  end

  defp source_build_dir(%Project{} = project) do
    Path.join(Project.root_path(project), "_build")
  end

  defp with_deleted_env(name, fun) do
    original = System.fetch_env(name)
    System.delete_env(name)

    try do
      fun.()
    after
      restore_env(name, original)
    end
  end

  defp restore_env(name, {:ok, value}), do: System.put_env(name, value)
  defp restore_env(name, :error), do: System.delete_env(name)

  defp beam_app_paths(build_dir) do
    Path.wildcard(Path.join([build_dir, "lib", "*"]))
  end

  defp beam_files(app_path) do
    Path.wildcard(Path.join([app_path, "ebin", "*.beam"]))
  end
end
