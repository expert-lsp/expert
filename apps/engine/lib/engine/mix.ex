defmodule Engine.Mix do
  alias Forge.Internet
  alias Forge.Project

  require Logger

  @accepted_project_key {__MODULE__, :accepted_project}
  @initial_project_diagnostics_key {__MODULE__, :initial_project_diagnostics}

  def loaded? do
    not is_nil(Mix.Project.get())
  end

  def accept_project(%Project{} = project, modules) when is_list(modules) do
    :persistent_term.put(@accepted_project_key, %{
      modules: modules,
      path: project |> Project.mix_exs_path() |> Path.expand()
    })

    :ok
  end

  def project_file?(path) do
    path = Path.expand(path)

    case :persistent_term.get(@accepted_project_key, nil) do
      %{path: ^path} ->
        true

      _ ->
        case Engine.get_project() do
          %Project{} = project ->
            project_path = Project.mix_exs_path(project)
            is_binary(project_path) and path == Path.expand(project_path)

          nil ->
            false
        end
    end
  end

  def compile_project(path, quoted_ast, compile) when is_function(compile, 0) do
    Engine.with_lock(Engine.Mix.StackMutation, fn ->
      env = Mix.env()
      target = Mix.target()
      compiler_options = Code.compiler_options()
      code_paths = :code.get_path()

      try do
        Mix.ProjectStack.on_clean_slate(fn ->
          path = Path.expand(path)

          case :persistent_term.get(@accepted_project_key, nil) do
            %{path: ^path} = accepted ->
              Enum.each(accepted.modules, fn {module, _binary} -> purge_old_code(module) end)
              compile_accepted_project(accepted, quoted_ast, compile)

            _ ->
              compile_unaccepted_project(path, quoted_ast, compile)
          end
        end)
      after
        Code.compiler_options(compiler_options)
        Mix.env(env)
        Mix.target(target)
        Code.delete_paths(:code.get_path() -- code_paths)

        if :code.get_path() != code_paths do
          true = :code.set_path(code_paths)
        end
      end
    end)
  end

  @doc false
  def clear_accepted_project do
    :persistent_term.erase(@accepted_project_key)
    :ok
  end

  @doc false
  def put_initial_project_diagnostics(diagnostics) do
    :persistent_term.put(@initial_project_diagnostics_key, diagnostics)
  end

  @doc false
  def take_initial_project_diagnostics do
    diagnostics = :persistent_term.get(@initial_project_diagnostics_key, [])
    :persistent_term.erase(@initial_project_diagnostics_key)
    diagnostics
  end

  @doc false
  def discard_project_modules(path) do
    path
    |> modules_loaded_from()
    |> Enum.each(fn module ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end)
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
    with_lock(fn -> run_and_normalize(fn -> in_loaded_project(project, fun) end) end)
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
    if Mix.Project.project_file() == Project.mix_exs_path(project) do
      Mix.Project.get()
    end
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

  defp compile_accepted_project(accepted, quoted_ast, compile) do
    result = compile_in_task(compile, quoted_ast)
    rollback_project(accepted)
    result
  end

  defp compile_unaccepted_project(path, quoted_ast, compile) do
    result = compile_in_task(compile, quoted_ast)
    discard_project_modules(path)
    result
  end

  defp rollback_project(accepted) do
    accepted_modules = MapSet.new(accepted.modules, &elem(&1, 0))

    for module <- modules_loaded_from(accepted.path), module not in accepted_modules do
      unload_module(module)
    end

    for {module, binary} <- accepted.modules do
      purge_old_code(module)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(accepted.path), binary)
      purge_old_code(module)
    end
  end

  defp compile_in_task(compile, quoted_ast) do
    task =
      Task.Supervisor.async_nolink(Engine.TaskSupervisor, fn ->
        result =
          try do
            {:ok, compile.()}
          catch
            kind, reason -> {:error, kind, reason, __STACKTRACE__}
          end

        result
      end)

    case Task.yield(task, :infinity) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, kind, reason, stack}} -> compile_failure(kind, reason, stack, quoted_ast)
      {:exit, reason} -> compile_failure(:exit, reason, [], quoted_ast)
    end
  end

  defp compile_failure(kind, reason, stack, quoted_ast) do
    exception = RuntimeError.exception("mix.exs compilation #{failure_message(kind, reason)}")
    {{:exception, exception, stack, quoted_ast}, []}
  end

  defp failure_message(:throw, reason), do: "threw: #{inspect(reason)}"
  defp failure_message(:exit, reason), do: "exited: #{inspect(reason)}"
  defp failure_message(:error, reason), do: "failed: #{inspect(reason)}"

  defp modules_loaded_from(path) do
    uri = Forge.Document.Path.to_uri(path)

    for {module, _file} <- :code.all_loaded(),
        compile when is_list(compile) <- [module.module_info(:compile)],
        source when not is_nil(source) <- [compile[:source]],
        Forge.Document.Path.to_uri(to_string(source)) == uri,
        do: module
  end

  defp unload_module(module) do
    purge_old_code(module)

    if :code.delete(module) do
      purge_old_code(module)
    end
  end

  defp purge_old_code(module) do
    # Let in-flight calls leave old code instead of terminating their processes.
    if :code.soft_purge(module) do
      :ok
    else
      Process.sleep(1)
      purge_old_code(module)
    end
  end
end
