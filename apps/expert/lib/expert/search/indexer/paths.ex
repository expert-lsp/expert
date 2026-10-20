defmodule Expert.Search.Indexer.Paths do
  alias Expert.EngineApi
  alias Forge.Document
  alias Forge.Project

  defstruct source_paths: [],
            source_sizes: %{},
            beam_paths: [],
            applications: %{},
            unlisted_sources: nil

  @type t :: %__MODULE__{
          source_paths: [Path.t()],
          source_sizes: %{optional(Path.t()) => non_neg_integer()},
          beam_paths: [Path.t()],
          applications: %{optional(Path.t()) => atom()},
          unlisted_sources: {Path.t(), [Path.t()]} | nil
        }

  def for_project(%Project{} = project) do
    for_project(project, &EngineApi.project_configuration(project, &1))
  end

  def for_project(%Project{} = project, configuration) do
    project
    |> without_sources(configuration)
    |> list_sources()
  end

  def without_sources(%Project{} = project) do
    without_sources(project, &EngineApi.project_configuration(project, &1))
  end

  def without_sources(%Project{kind: :bare} = project, _configuration) do
    %__MODULE__{unlisted_sources: {Project.root_path(project), []}}
  end

  def without_sources(%Project{} = project, configuration) do
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

        dependencies = application_beams(info.build_path, dependency_apps)
        project_beams = application_beams(info.build_path, project_apps)
        artifacts = Enum.uniq(dependencies ++ project_beams)
        applications = Map.new(artifacts, fn {path, app} -> {Path.dirname(path), app} end)

        %__MODULE__{
          unlisted_sources: {root, excluded},
          beam_paths: Enum.map(artifacts, &elem(&1, 0)),
          applications: applications
        }

      {:error, _} ->
        excluded = [
          Project.workspace_path(project),
          Path.join(root, "deps"),
          Path.join(root, "_build")
        ]

        %__MODULE__{unlisted_sources: {root, excluded}}
    end
  end

  def list_sources(%__MODULE__{unlisted_sources: {root, excluded}} = paths) do
    {source_paths, source_sizes} = source_files(root, excluded)

    %__MODULE__{
      paths
      | source_paths: source_paths,
        source_sizes: source_sizes,
        unlisted_sources: nil
    }
  end

  def list_sources(%__MODULE__{} = paths), do: paths

  # The files `Forge.Path.glob([root, "**", "*.{ex,exs}"])` finds outside
  # `excluded`, and their sizes, which the walk stats anyway. Like the glob,
  # it skips hidden entries and follows links to directories. It doesn't go
  # into excluded directories, where a build directory alone can hold tens
  # of thousands of files.
  defp source_files(root, excluded) do
    excluded? = fn path -> Enum.any?(excluded, &Forge.Path.contains?(path, &1)) end

    found =
      root
      |> Forge.Path.normalize()
      |> walk(excluded?, [])
      |> Enum.map(fn {path, size} -> {Forge.Path.native(path), size} end)
      |> Enum.reject(fn {path, _size} -> excluded?.(path) end)
      |> Enum.sort()
      |> Enum.uniq_by(fn {path, _size} -> path end)

    {Enum.map(found, &elem(&1, 0)), Map.new(found)}
  end

  defp walk(directory, excluded?, found) do
    case :prim_file.list_dir(directory) do
      {:ok, names} ->
        Enum.reduce(names, found, &visit(directory, IO.chardata_to_string(&1), excluded?, &2))

      {:error, _} ->
        found
    end
  end

  defp visit(_directory, "." <> _hidden, _excluded?, found), do: found

  defp visit(directory, name, excluded?, found) do
    path = Path.join(directory, name)
    stat = File.stat(path)

    found =
      if source_name?(name) do
        size =
          case stat do
            {:ok, %File.Stat{size: size}} -> size
            _ -> 0
          end

        [{path, size} | found]
      else
        found
      end

    case stat do
      {:ok, %File.Stat{type: :directory}} ->
        if excluded?.(path), do: found, else: walk(path, excluded?, found)

      _ ->
        found
    end
  end

  defp source_name?(name), do: String.ends_with?(name, ".ex") or String.ends_with?(name, ".exs")

  defp application_beams(build_path, apps) do
    apps
    |> Enum.uniq()
    |> Enum.flat_map(fn app ->
      ebin = Path.join([build_path, "lib", Atom.to_string(app), "ebin"])
      Enum.map(beam_files(ebin), &{&1, app})
    end)
  end

  # What `Path.wildcard(ebin/*.beam)` returns, from one directory listing:
  # the wildcard also stats every entry, which is most of its cost on an ebin
  # with thousands of modules.
  defp beam_files(ebin) do
    case File.ls(ebin) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            String.ends_with?(name, ".beam"),
            not String.starts_with?(name, "."),
            do: Path.join(ebin, name)

      {:error, _} ->
        []
    end
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
