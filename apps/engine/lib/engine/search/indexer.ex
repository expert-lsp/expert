defmodule Engine.Search.Indexer do
  alias Engine.ApplicationCache
  alias Engine.Progress
  alias Engine.Search.Indexer
  alias Engine.Search.Indexer.Extractors
  alias Forge.Identifier
  alias Forge.ProcessCache
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require ProcessCache

  @indexable_extensions "*.{ex,exs}"

  # Deps files only contribute definitions to the index, so we skip pure-reference
  # extractors (the most expensive one being FunctionReference, which resolves
  # aliases and arity on every call site). ModuleAttribute stays because it
  # produces both definitions and references; the post-filter drops its references.
  @deps_extractors [
    Extractors.Module,
    Extractors.ModuleAttribute,
    Extractors.FunctionDefinition,
    Extractors.StructDefinition,
    Extractors.EctoSchema
  ]

  def create_index(%Project{} = project) do
    :ok = ApplicationCache.clear()

    ProcessCache.with_cleanup do
      deps_roots = dependency_roots(project)

      entries =
        project
        |> indexable_files()
        |> async_chunks(&index_path(&1, deps_roots))

      {:ok, entries}
    end
  after
    ApplicationCache.clear()
  end

  def update_index(%Project{} = project, backend) do
    :ok = ApplicationCache.clear()

    ProcessCache.with_cleanup do
      do_update_index(project, backend)
    end
  after
    ApplicationCache.clear()
  end

  defp do_update_index(%Project{} = project, backend) do
    path_to_ids =
      backend.reduce(%{}, fn
        %Entry{path: path} = entry, path_to_ids when is_integer(entry.id) ->
          Map.update(path_to_ids, path, entry.id, &max(&1, entry.id))

        _entry, path_to_ids ->
          path_to_ids
      end)

    project_files =
      project
      |> indexable_files()
      |> MapSet.new()

    previously_indexed_paths = MapSet.new(path_to_ids, fn {path, _} -> path end)

    new_paths = MapSet.difference(project_files, previously_indexed_paths)

    {paths_to_examine, paths_to_delete} =
      Enum.split_with(path_to_ids, fn {path, _} -> File.regular?(path) end)

    changed_paths =
      for {path, id} <- paths_to_examine,
          newer_than?(path, id) do
        path
      end

    paths_to_delete = Enum.map(paths_to_delete, &elem(&1, 0))

    paths_to_reindex = changed_paths ++ Enum.to_list(new_paths)
    deps_roots = dependency_roots(project)

    entries = async_chunks(paths_to_reindex, &index_path(&1, deps_roots))

    {:ok, entries, paths_to_delete}
  end

  defp index_path(path, deps_roots) do
    in_deps? = Enum.any?(deps_roots, &Forge.Path.contains?(path, &1))
    extractors = if in_deps?, do: @deps_extractors

    with {:ok, contents} <- File.read(path),
         {:ok, entries} <- Indexer.Source.index(path, contents, extractors) do
      if in_deps? do
        Enum.filter(entries, &(&1.subtype == :definition))
      else
        entries
      end
    else
      _ ->
        []
    end
  end

  # 128 K blocks indexed expert in 5.3 seconds
  @bytes_per_block 1024 * 128

  defp async_chunks(file_paths, processor, timeout \\ :infinity) do
    # this function tries to even out the amount of data processed by
    # async stream by making each chunk emitted by the initial stream to
    # be roughly equivalent

    # Shuffling the results helps speed in some projects, as larger files tend to clump
    # together, like when there are auto-generated elixir modules.
    paths_to_sizes =
      file_paths
      |> path_to_sizes()
      |> Enum.shuffle()

    total_bytes = paths_to_sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total_bytes > 0 do
      process_chunks(paths_to_sizes, total_bytes, processor, timeout)
    else
      []
    end
  end

  defp process_chunks(paths_to_sizes, total_bytes, processor, timeout) do
    path_to_size_map = Map.new(paths_to_sizes)

    Progress.with_tracked_progress("Indexing source code", total_bytes, fn report ->
      start_time = System.monotonic_time(:millisecond)
      result = do_process_chunks(paths_to_sizes, path_to_size_map, processor, timeout, report)
      elapsed = System.monotonic_time(:millisecond) - start_time
      {:done, result, "Completed in #{format_duration(elapsed)}"}
    end)
  end

  defp do_process_chunks(paths_to_sizes, path_to_size_map, processor, timeout, report) do
    initial_state = {0, []}

    chunk_fn = fn {path, file_size}, {block_size, paths} ->
      new_block_size = file_size + block_size
      new_paths = [path | paths]

      if new_block_size >= @bytes_per_block do
        {:cont, new_paths, initial_state}
      else
        {:cont, {new_block_size, new_paths}}
      end
    end

    after_fn = fn
      {_, []} -> {:cont, []}
      {_, paths} -> {:cont, paths, []}
    end

    paths_to_sizes
    |> Stream.chunk_while(initial_state, chunk_fn, after_fn)
    |> Task.async_stream(
      fn chunk ->
        block_bytes = chunk |> Enum.map(&Map.get(path_to_size_map, &1)) |> Enum.sum()

        report.(message: "Indexing", add: block_bytes)

        Enum.flat_map(chunk, processor)
      end,
      timeout: timeout
    )
    |> Stream.flat_map(fn
      {:ok, entries} -> entries
      _ -> []
    end)
    |> Enum.to_list()
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp path_to_sizes(paths) do
    Enum.reduce(paths, [], fn file_path, acc ->
      case File.stat(file_path) do
        {:ok, %File.Stat{} = stat} ->
          [{file_path, stat.size} | acc]

        _ ->
          acc
      end
    end)
  end

  defp newer_than?(path, entry_id) do
    case stat(path) do
      {:ok, %File.Stat{} = stat} ->
        stat.mtime > Identifier.to_erl(entry_id)

      _ ->
        false
    end
  end

  def indexable_files(%Project{} = project) do
    roots = index_roots(project)
    excluded_roots = excluded_index_roots(project)

    roots
    |> Enum.flat_map(&Forge.Path.glob([&1, "**", @indexable_extensions]))
    |> Enum.uniq()
    |> Enum.reject(fn path -> Enum.any?(excluded_roots, &Forge.Path.contains?(path, &1)) end)
  end

  defp index_roots(%Project{} = project) do
    [Project.root_path(project) | dependency_roots(project)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp excluded_index_roots(%Project{kind: :mix} = project) do
    {runtime_build_path, configured_build_root} = build_paths(project)
    relative_build_root = Path.relative_to(configured_build_root, Project.root_path(project))

    project
    |> index_roots()
    |> Enum.map(&Path.expand(relative_build_root, &1))
    |> then(&[runtime_build_path, configured_build_root | &1])
    |> Enum.uniq()
  end

  defp excluded_index_roots(%Project{}), do: []

  # stat(path) is here for testing so it can be mocked
  defp stat(path) do
    File.stat(path)
  end

  defp dependency_roots(%Project{kind: :mix} = project) do
    [deps_dir(project) | path_dependency_roots(project)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dependency_roots(%Project{}), do: []

  defp deps_dir(%Project{kind: :mix} = project) do
    case Engine.Mix.in_project(project, &Mix.Project.deps_path/0) do
      {:ok, path} -> path
      _ -> Mix.Project.deps_path()
    end
  end

  defp deps_dir(%Project{}), do: nil

  defp path_dependency_roots(%Project{} = project) do
    case Engine.Mix.in_project(project, fn _ ->
           path_dependency_roots(Mix.Project.config(), Mix.env())
         end) do
      {:ok, roots} -> Enum.flat_map(roots, &mix_source_roots/1)
      _ -> []
    end
  end

  defp path_dependency_roots(config, env) do
    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(&path_dependency_root(&1, env))
  end

  defp path_dependency_root({_app, opts}, env) when is_list(opts) do
    path_dependency_root_from_opts(opts, env)
  end

  defp path_dependency_root({_app, _requirement, opts}, env) when is_list(opts) do
    path_dependency_root_from_opts(opts, env)
  end

  defp path_dependency_root(_dep, _env), do: []

  defp path_dependency_root_from_opts(opts, env) do
    with true <- dependency_active?(opts, env),
         path when is_binary(path) <- Keyword.get(opts, :path) do
      [Path.expand(path, File.cwd!())]
    else
      _ -> []
    end
  end

  defp dependency_active?(opts, env) do
    only_active?(Keyword.get(opts, :only), env) and
      not except_active?(Keyword.get(opts, :except), env)
  end

  defp only_active?(nil, _env), do: true
  defp only_active?(only, env) when is_atom(only), do: only == env
  defp only_active?(only, env) when is_list(only), do: env in only

  defp except_active?(nil, _env), do: false
  defp except_active?(except, env) when is_atom(except), do: except == env
  defp except_active?(except, env) when is_list(except), do: env in except

  defp mix_source_roots(root) do
    project = root |> Forge.Document.Path.to_uri() |> Project.new()

    source_paths =
      case Engine.Mix.in_project(project, fn _ ->
             Keyword.get(Mix.Project.config(), :elixirc_paths, ["lib"])
           end) do
        {:ok, paths} -> paths
        _ -> ["lib"]
      end

    Enum.map(source_paths, &Path.expand(&1, root))
  end

  defp build_paths(%Project{kind: :mix} = project) do
    case Engine.Mix.in_project(project, fn project_module ->
           {Mix.Project.build_path(), configured_build_root(project, project_module.project())}
         end) do
      {:ok, paths} -> paths
      _ -> {Mix.Project.build_path(), configured_build_root(project, [])}
    end
  end

  defp configured_build_root(%Project{} = project, config) do
    config = Keyword.put_new(config, :build_per_environment, true)
    mix_build_path = System.get_env("MIX_BUILD_PATH")
    System.delete_env("MIX_BUILD_PATH")

    try do
      project
      |> Project.root_path()
      |> File.cd!(fn ->
        config
        |> Mix.Project.build_path()
        |> Path.dirname()
      end)
    after
      if is_binary(mix_build_path) do
        System.put_env("MIX_BUILD_PATH", mix_build_path)
      else
        System.delete_env("MIX_BUILD_PATH")
      end
    end
  end
end
