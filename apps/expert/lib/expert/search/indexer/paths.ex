defmodule Expert.Search.Indexer.Paths do
  alias Expert.EngineApi
  alias Forge.Document
  alias Forge.Project

  @indexable_extensions "*.{ex,exs}"

  defstruct source_paths: [], beam_paths: [], applications: %{}

  @type t :: %__MODULE__{
          source_paths: [Path.t()],
          beam_paths: [Path.t()],
          applications: %{optional(Path.t()) => atom()}
        }

  def for_project(%Project{} = project) do
    for_project(project, &EngineApi.project_configuration(project, &1))
  end

  def for_project(%Project{kind: :bare} = project, _configuration) do
    %__MODULE__{source_paths: source_files(Project.root_path(project), [])}
  end

  def for_project(%Project{} = project, configuration) do
    root = Project.root_path(project)

    case configuration.(project) do
      {:ok, info} ->
        {configured_apps, dependency_roots} =
          configured_dependencies(root, info, configuration, [])

        resolved_apps =
          case info.dependency_apps do
            {:ok, apps} -> apps
            {:error, _} -> []
          end

        dependency_apps = Enum.uniq(resolved_apps ++ configured_apps)

        project_apps =
          case info.apps_paths do
            nil -> List.wrap(info.config[:app])
            apps -> Map.keys(apps)
          end

        dependency_roots = Enum.uniq([info.deps_path | dependency_roots])
        build_root = configured_build_root(root, info)
        relative_build_root = Path.relative_to(build_root, root)
        build_roots = Enum.map([root | dependency_roots], &Path.expand(relative_build_root, &1))

        excluded = [
          Project.workspace_path(project),
          info.build_path,
          build_root | dependency_roots ++ build_roots
        ]

        sources = source_files(root, excluded)
        dependencies = application_beams(info.build_path, dependency_apps)
        project_beams = application_beams(info.build_path, project_apps)
        artifacts = Enum.uniq(dependencies ++ project_beams)
        applications = Map.new(artifacts, fn {path, app} -> {Path.dirname(path), app} end)

        %__MODULE__{
          source_paths: sources,
          beam_paths: Enum.map(artifacts, &elem(&1, 0)),
          applications: applications
        }

      {:error, _} ->
        excluded = [
          Project.workspace_path(project),
          Path.join(root, "deps"),
          Path.join(root, "_build")
        ]

        %__MODULE__{source_paths: source_files(root, excluded)}
    end
  end

  defp source_files(root, excluded) do
    [root, "**", @indexable_extensions]
    |> Forge.Path.glob()
    |> Enum.reject(fn path -> Enum.any?(excluded, &Forge.Path.contains?(path, &1)) end)
    |> Enum.uniq()
  end

  defp application_beams(build_path, apps) do
    apps
    |> Enum.uniq()
    |> Enum.flat_map(fn app ->
      [build_path, "lib", Atom.to_string(app), "ebin", "*.beam"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(&{&1, app})
    end)
  end

  defp configured_build_root(root, info) do
    case info.project_config[:deps_build_path] do
      path when is_binary(path) -> Path.expand(Path.dirname(path), root)
      nil -> Path.expand(info.build_root || info.project_config[:build_path] || "_build", root)
    end
  end

  defp configured_dependencies(root, info, configuration, seen) do
    if root in seen do
      {[], []}
    else
      seen = [root | seen]

      dependencies =
        info.config
        |> Keyword.get(:deps, [])
        |> Enum.flat_map(&dependency(&1, info.env, info.target))

      apps =
        for {app, opts} <- dependencies,
            app = Keyword.get(opts, :app, app),
            is_atom(app) and app != false,
            do: app

      roots =
        for {_, opts} <- dependencies,
            path = opts[:path],
            is_binary(path),
            do: Path.expand(path, root)

      Enum.reduce(roots, {apps, roots}, fn path, {apps, roots} ->
        project = Project.new(Document.Path.to_uri(path))

        project = %{
          project
          | mix_exs_uri: Document.Path.to_uri(Path.join(path, "mix.exs")),
            kind: :mix
        }

        case configuration.(project) do
          {:ok, child_info} ->
            {child_apps, child_roots} =
              configured_dependencies(path, child_info, configuration, seen)

            {Enum.uniq(apps ++ child_apps), Enum.uniq(roots ++ child_roots)}

          {:error, _} ->
            {apps, roots}
        end
      end)
    end
  end

  defp dependency({app, opts}, env, target) when is_atom(app) and is_list(opts),
    do: active_dependency(app, opts, env, target)

  defp dependency({app, _requirement, opts}, env, target) when is_atom(app) and is_list(opts),
    do: active_dependency(app, opts, env, target)

  defp dependency({app, _requirement}, _env, _target) when is_atom(app), do: [{app, []}]
  defp dependency(_, _, _), do: []

  defp active_dependency(app, opts, env, target) do
    environments = List.wrap(opts[:only])
    targets = List.wrap(opts[:targets])

    if (environments == [] or env in environments) and (targets == [] or target in targets),
      do: [{app, opts}],
      else: []
  end
end
