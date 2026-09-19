defmodule Engine.Mix do
  alias Engine.Build.Isolation
  alias Forge.Internet
  alias Forge.Project

  require Logger

  @modules_key {__MODULE__, :root_modules}

  def loaded? do
    not is_nil(Mix.Project.get())
  end

  def project_file?(path) do
    path = Path.expand(path)

    Path.basename(path) == "mix.exs" or
      case Engine.get_project() do
        %Project{} = project ->
          project_path = Project.mix_exs_path(project)
          is_binary(project_path) and Path.expand(project_path) == path

        nil ->
          false
      end
  end

  @doc "Reloads the saved Mix project and runs the build before releasing the project lock."
  def reload_project(%Project{} = project, fun \\ fn _project -> {:ok, []} end) do
    with_lock(fn ->
      File.cd!(Project.root_path(project), fn ->
        case load_project(project) do
          {:ok, loaded, diagnostics} ->
            Engine.set_project(loaded)
            Project.put_config(loaded, Mix.Project.config())
            {status, build_diagnostics} = fun.(loaded)

            {status, diagnostics ++ build_diagnostics}

          {:error, diagnostics} ->
            mark_project_unavailable(project)
            {:error, diagnostics}
        end
      end)
    end)
  end

  defp load_project(project) do
    clear_project()
    Project.put_config(project, [])
    path = Project.mix_exs_path(project)
    env = Mix.env()
    target = Mix.target()
    compiler_options = Code.compiler_options()

    try do
      Code.compiler_options(
        tracers: [],
        ignore_module_conflict: true,
        no_warn_undefined: :all,
        relative_paths: false
      )

      Mix.ProjectStack.post_config(
        build_path: Project.versioned_build_path(project),
        prune_code_paths: false
      )

      case Isolation.with_diagnostics(path, fn -> compile_project_file(project, path) end) do
        {:ok, loaded, diagnostics} ->
          {:ok, loaded, diagnostics}

        {:error, diagnostics} ->
          unload_modules(modules_loaded_from(path))
          clear_project()
          {:error, diagnostics}
      end
    after
      Code.compiler_options(compiler_options)
      Mix.env(env)
      Mix.target(target)
    end
  end

  defp compile_project_file(project, path) do
    modules = for {module, _binary} <- Code.compile_file(path), do: module
    :persistent_term.put(@modules_key, modules)
    module = Mix.Project.get()
    file = Mix.Project.project_file()

    if is_nil(module) or not is_binary(file) or Path.expand(file) != Path.expand(path) do
      Mix.raise("mix.exs does not define a Mix project")
    end

    Mix.Task.run(:loadconfig)
    Project.set_project_module(project, module)
  end

  defp clear_project do
    for {app, values} <- Mix.State.read_cache(Mix.Tasks.Loadconfig) || [],
        app == :logger or app not in Engine.required_apps(),
        {key, _value} <- values do
      Application.delete_env(app, key, persistent: true)
    end

    # Mix caches each dependency's project module and source path. Collect these
    # before clearing the cache, including children from a failed dependency load.
    children =
      for {{Mix.State, {:app, _app}}, {module, _file}} <- :persistent_term.get(),
          is_atom(module) and not is_nil(module),
          do: module

    modules = pop_projects(:persistent_term.get(@modules_key, []) ++ children)
    Mix.ProjectStack.clear_stack()
    Mix.State.clear_cache()
    Mix.Task.clear()
    :persistent_term.erase(@modules_key)
    unload_modules(Enum.uniq(modules))
  end

  defp pop_projects(modules) do
    case Mix.Project.pop() do
      nil -> modules
      %{name: nil} -> pop_projects(modules)
      %{name: module} -> pop_projects([module | modules])
    end
  end

  defp unload_modules(modules) do
    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end)

    if Process.whereis(Engine.Module.Loader) do
      Engine.Module.Loader.forget(modules)
    end
  end

  defp modules_loaded_from(path) do
    path = Path.expand(path)

    for {module, []} <- :code.all_loaded(),
        source when not is_nil(source) <- [module.module_info(:compile)[:source]],
        Path.expand(to_string(source)) == path,
        do: module
  end

  defp mark_project_unavailable(%Project{} = project) do
    Engine.set_project(Project.set_project_module(project, nil))
    Project.put_config(project, [])
  end

  def ensure_hex_and_rebar do
    if Internet.connected_to_internet?() do
      Mix.Task.run("local.hex", ~w(--force --if-missing))
      Mix.Task.run("local.rebar", ~w(--force --if-missing))
      :ok
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
      :ok
    end
  end

  def in_project(fun) do
    case Engine.get_project() do
      %Project{} = project ->
        in_project(project, fun)

      _ ->
        {:error, :not_project_node}
    end
  end

  def in_project(%Project{kind: :bare}, fun) do
    run_and_normalize(fn -> fun.(nil) end)
  end

  def in_project(%Project{kind: :mix} = project, fun) do
    with_lock(fn ->
      case Engine.get_project() do
        %Project{root_uri: root_uri, entropy: entropy, project_module: nil}
        when root_uri == project.root_uri and entropy == project.entropy ->
          {:error, :project_not_loaded}

        _ ->
          project = current_project(project)
          run_and_normalize(fn -> in_loaded_project(project, fun) end)
      end
    end)
  end

  defp current_project(project) do
    case Engine.get_project() do
      %Project{root_uri: root_uri, entropy: entropy} = current
      when root_uri == project.root_uri and entropy == project.entropy ->
        current

      _ ->
        project
    end
  end

  def deps_paths do
    :persistent_term.get({__MODULE__, :deps_paths}, %{})
  end

  def deps_formatter_opts do
    {_, formatter_opts} = :persistent_term.get({__MODULE__, :deps_formatter}, {%{}, %{}})
    formatter_opts
  end

  defp ensure_project_loaded(%Project{kind: :mix, project_module: nil} = project) do
    load_project_from_mix_exs(project)
  end

  defp ensure_project_loaded(%Project{} = project), do: project

  defp load_project_from_mix_exs(%Project{} = project) do
    build_path = Project.versioned_build_path(project)
    mix_exs_dir = project |> Project.mix_exs_path() |> Path.dirname()

    # Mix.Project.in_project/4 loads and caches the mix.exs module, but pushes
    # and pops it to do so, which is why it runs under the same StackMutation
    # lock as the push that follows it.
    Mix.Project.in_project(
      Project.atom_name(project),
      mix_exs_dir,
      [build_path: build_path],
      fn project_module ->
        Project.set_project_module(project, project_module)
      end
    )
  end

  defp in_loaded_project(%Project{} = project, fun) do
    File.cd!(Project.root_path(project), fn ->
      with_pushed_project(project, fn project_module ->
        fun.(project_module)
      end)
    end)
  end

  # Only the push and the pop take the StackMutation lock, never fun: it is a
  # whole compile under in_project/2, and formatter resolution is what #804 took
  # out from under a lock.
  defp with_pushed_project(%Project{} = project, fun) do
    {ownership, project_module} =
      Engine.with_lock(Engine.Mix.StackMutation, fn -> push_or_borrow(project) end)

    try do
      fun.(project_module)
    after
      Engine.with_lock(Engine.Mix.StackMutation, fn -> release_project(ownership) end)
    end
  end

  def record_deps(%Project{} = project) do
    deps_paths = Mix.Project.deps_paths()
    put_persistent({__MODULE__, :deps_paths}, deps_paths)
    record_deps_formatter_opts(project, deps_paths)
  rescue
    ex ->
      Logger.warning("Could not record dependency formatter options: #{Exception.message(ex)}")
  end

  defp record_deps_formatter_opts(%Project{} = project, deps_paths) do
    project_config = Mix.Project.config()
    imported_deps = imported_formatter_deps(Project.root_path(project))
    key = {__MODULE__, :deps_formatter}
    {previous_sources, previous_opts} = :persistent_term.get(key, {%{}, %{}})

    {sources, formatter_opts} =
      Enum.reduce(imported_deps, {%{}, %{}}, fn dep, {sources, formatter_opts} ->
        with {:ok, dep_path} <- Map.fetch(deps_paths, dep),
             formatter_path = Path.join(dep_path, ".formatter.exs"),
             {:ok, contents} <- File.read(formatter_path) do
          source = {formatter_path, contents, project_config}

          opts =
            if previous_sources[dep] == source do
              previous_opts[dep]
            else
              {opts, _binding} = Code.eval_file(formatter_path)
              true = Keyword.keyword?(opts)
              opts
            end

          {Map.put(sources, dep, source), Map.put(formatter_opts, dep, opts)}
        else
          _ -> {sources, formatter_opts}
        end
      end)

    put_persistent(key, {sources, formatter_opts})
  end

  defp imported_formatter_deps(root_path) do
    root_path
    |> collect_formatter_deps(MapSet.new())
    |> MapSet.to_list()
  end

  defp collect_formatter_deps(dir, deps) do
    formatter_path = Path.join(dir, ".formatter.exs")

    with true <- File.regular?(formatter_path),
         {opts, _binding} <- Code.eval_file(formatter_path) do
      deps = Enum.reduce(Keyword.get(opts, :import_deps, []), deps, &MapSet.put(&2, &1))

      opts
      |> Keyword.get(:subdirectories, [])
      |> Enum.flat_map(&Path.wildcard(Path.expand(&1, dir)))
      |> Enum.reduce(deps, &collect_formatter_deps/2)
    else
      _ -> deps
    end
  end

  defp put_persistent(key, value) do
    if :persistent_term.get(key, :missing) != value do
      :persistent_term.put(key, value)
    end
  end

  # Mix.Project.config/0 only reflects the project while it is on the project
  # stack, and Mix.Project.push/3 refuses a module that is already there, so a
  # project someone else pushed is borrowed and left for them to pop. Callers
  # hold the StackMutation lock.
  defp push_or_borrow(%Project{} = project) do
    if module = pushed_module(project) do
      {:borrowed, module}
    else
      project = ensure_project_loaded(project)
      push_project(project)
      {:pushed, project.project_module}
    end
  end

  defp release_project(:borrowed), do: :ok
  defp release_project(:pushed), do: Mix.Project.pop()

  defp pushed_module(%Project{} = project) do
    project_file = Mix.Project.project_file()

    if is_binary(project_file) and
         normalize_path(project_file) == normalize_path(Project.mix_exs_path(project)) do
      Mix.Project.get()
    end
  end

  defp normalize_path(path) do
    path
    |> Forge.Path.normalize()
    |> Path.expand()
  end

  defp push_project(%Project{} = project) do
    Mix.ProjectStack.post_config(build_path: Project.versioned_build_path(project))

    try do
      Mix.Project.push(
        project.project_module,
        Project.mix_exs_path(project),
        Project.atom_name(project)
      )
    rescue
      ex ->
        # Only a successful push consumes the post_config; leaving it behind
        # would give the next project Mix pushes the engine's build path.
        Mix.ProjectStack.pop_post_config(:build_path)
        reraise ex, __STACKTRACE__
    end
  end

  defp run_and_normalize(fun) do
    fun.()
    |> normalize_result()
  rescue
    ex ->
      exception_error(ex, __STACKTRACE__)
  end

  defp normalize_result(result) do
    case result do
      error when is_tuple(error) and elem(error, 0) == :error ->
        error

      ok when is_tuple(ok) and elem(ok, 0) == :ok ->
        ok

      other ->
        {:ok, other}
    end
  end

  defp exception_error(exception, stacktrace) do
    blamed = Exception.blame(:error, exception, stacktrace)
    {:error, {:exception, blamed, stacktrace}}
  end

  defp with_lock(fun) do
    Engine.with_lock(__MODULE__, fun)
  end
end
