defmodule Engine.Compilation.Tracer do
  use GenServer

  import Forge.EngineApi.Messages

  alias Engine.Build
  alias Engine.Module.Loader
  alias Engine.Progress

  @table __MODULE__

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init([]) do
    table = :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    {:ok, table}
  end

  # calls from unsaved editor text are returned with the compile result instead of written
  def document_compile(fun) do
    :ets.insert(@table, {:document_compile, true})

    try do
      result = fun.()
      {result, take(@table, {:document_compile, :defined})}
    after
      :ets.delete(@table, :document_compile)
    end
  end

  # The lexical tracker identifies the file being compiled across its events.
  def trace({kind, meta, module, name, arity}, %Macro.Env{} = env)
      when kind in [:imported_function, :imported_macro] do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      call = {line, column, Atom.to_string(module), Atom.to_string(name), arity}
      :ets.insert(@table, {{env.lexical_tracker, :pending, env.module}, call})
    end

    :ok
  end

  def trace({:on_module, module_binary, _filename}, %Macro.Env{} = env) do
    imported_calls = take(@table, {env.lexical_tracker, :pending, env.module})

    if :ets.member(@table, :document_compile) do
      :ets.insert(@table, {{:document_compile, :defined}, {env.module, imported_calls}})
    else
      write_imported_calls(env.module, env.file, imported_calls)
    end

    message = extract_module_updated(env.module, module_binary, env.file)
    maybe_report_progress(env.file)
    Engine.broadcast(message)
    :ok
  end

  # a module that failed to compile never reached on_module
  def trace(:stop, %Macro.Env{} = env) do
    :ets.match_delete(@table, {{env.lexical_tracker, :pending, :_}, :_})
    :ok
  end

  def trace(_event, _env) do
    :ok
  end

  def extract_module_updated(module, module_binary, filename) do
    if !Loader.ensure_loaded?(module) do
      :code.load_binary(module, [], module_binary)
    end

    functions = module.__info__(:functions)
    macros = module.__info__(:macros)

    struct =
      if function_exported?(module, :__struct__, 0) do
        module.__struct__()
        |> Map.from_struct()
        |> Enum.map(fn {k, v} ->
          %{field: k, required?: !is_nil(v)}
        end)
      end

    module_updated(
      file: filename,
      functions: functions,
      macros: macros,
      name: module,
      struct: struct
    )
  end

  # Mix deletes a removed module's beam and leaves the file next to it behind
  def prune_imported_calls(build_path) do
    for ebin <- Path.wildcard(Path.join(build_path, "lib/*/ebin")) do
      names = File.ls!(ebin)

      beams =
        for name <- names,
            Path.extname(name) == ".beam",
            into: MapSet.new(),
            do: Path.rootname(name)

      for name <- names,
          Path.extname(name) == ".imported_calls",
          not MapSet.member?(beams, Path.rootname(name)),
          do: File.rm!(Path.join(ebin, name))
    end

    :ok
  end

  defp write_imported_calls(module, file, imported_calls) do
    # only an app has a compile path, and only .ex files get beams there
    if Mix.Project.config()[:app] && Path.extname(file) == ".ex" do
      path = Path.join(Mix.Project.compile_path(), "#{module}.imported_calls")
      File.write!(path, :erlang.term_to_binary({file, imported_calls}))
    end
  end

  defp take(table, key) do
    for {_key, value} <- :ets.take(table, key), do: value
  end

  defp maybe_report_progress(file) do
    with ".ex" <- Path.extname(file),
         token when not is_nil(token) <- Build.get_progress_token() do
      Progress.report(token, message: progress_message(file))
    end
  end

  defp progress_message(file) do
    relative_path_elements =
      file
      |> Path.relative_to_cwd()
      |> Path.split()

    base_dir = List.first(relative_path_elements)
    file_name = List.last(relative_path_elements)

    "compiling: " <> Path.join([base_dir, "...", file_name])
  end
end
