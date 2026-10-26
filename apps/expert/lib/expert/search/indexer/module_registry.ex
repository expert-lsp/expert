defmodule Expert.Search.Indexer.ModuleRegistry do
  @moduledoc """
  Stores module metadata read from BEAM files without loading their modules.
  """

  use GenServer

  alias Expert.EngineApi
  alias Expert.Project.Store
  alias Forge.Project

  @type exports :: %{functions: [{atom(), arity()}], macros: [{atom(), arity()}]}
  @type module_metadata :: %{
          application: atom() | nil,
          beam_path: Path.t() | nil,
          exports: exports()
        }
  @type position :: {pos_integer(), pos_integer()}
  @type imported_call :: {String.t(), String.t(), arity()}
  @type imported_calls :: {Path.t(), %{position() => imported_call()}}

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def name(%Project{root_uri: root_uri} = project) do
    key = {__MODULE__, root_uri}

    case :persistent_term.get(key, nil) do
      nil ->
        name = :"#{Project.unique_name(project)}::module_registry"
        :persistent_term.put(key, name)
        name

      name ->
        name
    end
  end

  def clear(%Project{} = project), do: GenServer.call(name(project), :clear)

  def prune(%Project{} = project, beam_paths) do
    GenServer.call(name(project), {:prune, MapSet.new(beam_paths, &Forge.Path.native/1)})
  end

  @impl GenServer
  def init(project) do
    table =
      :ets.new(name(project), [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end

  @impl GenServer
  def handle_call(:clear, _from, table) do
    :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  def handle_call({:prune, beam_paths}, _from, table) do
    :ets.select_delete(table, [
      {{{:"$1", :_}, :_}, [{:"=/=", :"$1", :module}], [true]}
    ])

    for {module, beam_path} <-
          :ets.select(table, [
            {{{:module, :"$1"}, %{beam_path: :"$2"}}, [], [{{:"$1", :"$2"}}]}
          ]),
        !MapSet.member?(beam_paths, beam_path) do
      :ets.delete(table, {:module, module})
    end

    {:reply, :ok, table}
  end

  @spec put(
          Project.t(),
          module(),
          Path.t(),
          atom() | nil,
          [{atom(), arity()}]
        ) :: :ok
  def put(%Project{} = project, module, beam_path, application, beam_exports) do
    put_all(project, [{module, beam_path, application, beam_exports}])
  end

  @spec put_all(
          Project.t(),
          [{module(), Path.t(), atom() | nil, [{atom(), arity()}]}]
        ) :: :ok
  def put_all(%Project{} = _project, []), do: :ok

  def put_all(%Project{} = project, modules) when is_list(modules) do
    objects =
      Enum.map(modules, fn {module, beam_path, application, beam_exports} ->
        metadata = %{
          application: application,
          beam_path: Forge.Path.native(beam_path),
          exports: exports_from_beam_chunk(beam_exports)
        }

        {{:module, module}, metadata}
      end)

    true = :ets.insert(name(project), objects)
    :ok
  end

  # the compiler's trace is written next to the beam, with the file it compiled
  @spec imported_calls(Project.t(), module()) :: imported_calls() | nil
  def imported_calls(%Project{} = project, module) when is_atom(module) do
    with beam_path when is_binary(beam_path) <- beam_path(project, module),
         {:ok, binary} <- read_file(Path.rootname(beam_path) <> ".imported_calls") do
      {file, calls} = :erlang.binary_to_term(binary, [:safe])

      {Forge.Path.native(file),
       Map.new(calls, fn {line, column, imported_module, name, arity} ->
         {{line, column}, {imported_module, name, arity}}
       end)}
    else
      _ -> nil
    end
  end

  # every source worker reads these at once, and the file server would serialize them
  defp read_file(path) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, size} <- :file.position(fd, :eof), do: :file.pread(fd, 0, size)
      after
        :file.close(fd)
      end
    end
  end

  @spec application(Project.t() | nil, module() | nil) :: atom() | nil
  def application(_project, nil), do: nil
  def application(nil, _module), do: nil

  def application(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), {:module, module}) do
      [{{:module, ^module}, %{application: nil}}] ->
        engine_lookup(project, :application, module, nil)

      [{{:module, ^module}, %{application: application}}] ->
        application

      [] ->
        engine_lookup(project, :application, module, nil)
    end
  end

  @spec available_module?(Project.t() | nil, module()) :: boolean()
  def available_module?(nil, _module), do: false

  def available_module?(%Project{} = project, module) when is_atom(module) do
    :ets.member(name(project), {:module, module}) or
      engine_lookup(project, :available_module?, module, false)
  end

  @spec module_exports(Project.t() | nil, module()) :: {:ok, exports()} | :error
  def module_exports(nil, _module), do: :error

  def module_exports(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), {:module, module}) do
      [{{:module, ^module}, %{exports: exports}}] -> {:ok, exports}
      [] -> engine_lookup(project, :module_exports, module, :error)
    end
  end

  @spec beam_path(Project.t() | nil, module()) :: Path.t() | nil
  def beam_path(nil, _module), do: nil

  def beam_path(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), {:module, module}) do
      [{{:module, ^module}, %{beam_path: beam_path}}] -> beam_path
      [] -> nil
    end
  end

  def exunit_module?(nil, _module), do: false

  def exunit_module?(%Project{} = project, module),
    do: engine_lookup(project, :exunit_module?, module, false)

  defp engine_lookup(project, operation, module, default) do
    if Store.ready?(project) do
      fetch_from_engine(project, operation, module)
    else
      default
    end
  end

  defp fetch_from_engine(project, operation, module) do
    table = name(project)
    key = {operation, module}

    case :ets.lookup(table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = apply(EngineApi, operation, [project, module])
        if value != :error, do: :ets.insert(table, {key, value})
        value
    end
  end

  defp exports_from_beam_chunk(beam_exports) do
    exports =
      Enum.reduce(beam_exports, %{functions: [], macros: []}, fn export, exports ->
        case classify_export(export) do
          {:function, function} -> Map.update!(exports, :functions, &[function | &1])
          {:macro, macro} -> Map.update!(exports, :macros, &[macro | &1])
          :skip -> exports
        end
      end)

    Map.new(exports, fn {type, values} -> {type, Enum.sort(values)} end)
  end

  defp classify_export({name, _arity}) when name in [:__info__, :module_info], do: :skip

  defp classify_export({name, arity}) when is_atom(name) and arity > 0 do
    case Atom.to_string(name) do
      "MACRO-" <> macro_name -> {:macro, {String.to_atom(macro_name), arity - 1}}
      _function_name -> {:function, {name, arity}}
    end
  end

  defp classify_export({name, arity}) when is_atom(name), do: {:function, {name, arity}}
  defp classify_export(_export), do: :skip
end
