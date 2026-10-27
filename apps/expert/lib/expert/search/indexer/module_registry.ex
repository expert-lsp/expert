defmodule Expert.Search.Indexer.ModuleRegistry do
  @moduledoc """
  Stores module metadata read from BEAM files without loading their modules.
  """

  use GenServer

  alias Expert.EngineApi
  alias Expert.Project.Store
  alias Expert.Search
  alias Expert.Search.Indexer.BeamFile
  alias Forge.Project

  require Logger

  @type stored_exports :: %{functions: BeamFile.exports(), macros: BeamFile.exports()}
  @type module_metadata :: %{
          application: atom() | nil,
          beam_path: Path.t() | nil,
          exports: stored_exports()
        }

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::module_registry"

  def clear(%Project{} = project), do: GenServer.call(name(project), :clear, :infinity)

  def prune(%Project{} = project, beam_paths) do
    beam_paths = MapSet.new(beam_paths, &Forge.Path.native/1)
    GenServer.call(name(project), {:prune, beam_paths}, :infinity)
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

    load(project, table)
    {:ok, table}
  end

  defp load(project, table) do
    case Search.Store.modules(project) do
      modules when is_list(modules) ->
        rows =
          for {beam_path, module, application, exports} <- modules do
            {{:module, module},
             %{application: application, beam_path: beam_path, exports: exports}}
          end

        true = :ets.insert(table, rows)

      {:error, reason} ->
        Logger.warning("Could not load stored modules: #{inspect(reason)}")
    end
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

    for {module, beam_path} <- module_beam_paths(table),
        !MapSet.member?(beam_paths, beam_path) do
      :ets.delete(table, {:module, module})
    end

    {:reply, :ok, table}
  end

  @spec put(Project.t(), String.t(), Path.t(), atom() | nil, BeamFile.exports()) :: :ok
  def put(%Project{} = project, module, beam_path, application, beam_exports) do
    put_all(project, [{module, beam_path, application, beam_exports}])
  end

  @spec put_all(Project.t(), [{String.t(), Path.t(), atom() | nil, BeamFile.exports()}]) :: :ok
  def put_all(%Project{} = _project, []), do: :ok

  def put_all(%Project{} = project, modules) when is_list(modules) do
    objects =
      Enum.map(modules, fn {module, beam_path, application, beam_exports}
                           when is_binary(module) ->
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

  @spec persist(Project.t()) :: :ok | {:error, term()}
  def persist(%Project{} = project) do
    Search.Store.replace_modules(project, modules(project))
  end

  @spec persist(Project.t(), [Path.t()], [Path.t()]) :: :ok | {:error, term()}
  def persist(%Project{} = project, changed_beam_paths, removed_beam_paths) do
    paths = Enum.map(changed_beam_paths ++ removed_beam_paths, &Forge.Path.native/1)
    Search.Store.update_modules(project, modules(project, changed_beam_paths), paths)
  end

  defp modules(%Project{} = project) do
    for {{:module, module}, metadata} <- :ets.match_object(name(project), {{:module, :_}, :_}) do
      {metadata.beam_path, module, metadata.application, metadata.exports}
    end
  end

  defp modules(%Project{} = project, beam_paths) do
    table = name(project)
    beam_paths = MapSet.new(beam_paths, &Forge.Path.native/1)

    for {module, beam_path} <- module_beam_paths(table), MapSet.member?(beam_paths, beam_path) do
      metadata = :ets.lookup_element(table, {:module, module}, 2)
      {beam_path, module, metadata.application, metadata.exports}
    end
  end

  @spec application(Project.t() | nil, module() | nil) :: atom() | nil
  def application(_project, nil), do: nil
  def application(nil, _module), do: nil

  def application(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), key(module)) do
      [{_key, %{application: nil}}] ->
        engine_lookup(project, :application, module, nil)

      [{_key, %{application: application}}] ->
        application

      [] ->
        engine_lookup(project, :application, module, nil)
    end
  end

  @spec available_module?(Project.t() | nil, module()) :: boolean()
  def available_module?(nil, _module), do: false

  def available_module?(%Project{} = project, module) when is_atom(module) do
    :ets.member(name(project), key(module)) or
      engine_lookup(project, :available_module?, module, false)
  end

  @spec module_exports(Project.t() | nil, module()) :: {:ok, stored_exports()} | :error
  def module_exports(nil, _module), do: :error

  def module_exports(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), key(module)) do
      [{_key, %{exports: exports}}] -> {:ok, exports}
      [] -> engine_lookup(project, :module_exports, module, :error)
    end
  end

  @spec beam_path(Project.t() | nil, module()) :: Path.t() | nil
  def beam_path(nil, _module), do: nil

  def beam_path(%Project{} = project, module) when is_atom(module) do
    case :ets.lookup(name(project), key(module)) do
      [{_key, %{beam_path: beam_path}}] -> beam_path
      [] -> nil
    end
  end

  def exunit_module?(nil, _module), do: false

  def exunit_module?(%Project{} = project, module),
    do: engine_lookup(project, :exunit_module?, module, false)

  defp key(module), do: {:module, Atom.to_string(module)}

  defp module_beam_paths(table) do
    :ets.select(table, [{{{:module, :"$1"}, %{beam_path: :"$2"}}, [], [{{:"$1", :"$2"}}]}])
  end

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

  defp classify_export({name, _arity}) when name in ["__info__", "module_info"], do: :skip

  defp classify_export({"MACRO-" <> macro, arity}) when arity > 0,
    do: {:macro, {macro, arity - 1}}

  defp classify_export({name, arity}) when is_binary(name), do: {:function, {name, arity}}
  defp classify_export(_export), do: :skip
end
