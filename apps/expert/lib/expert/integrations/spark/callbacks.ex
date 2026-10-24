defmodule Expert.Integrations.Spark.Callbacks do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Integrations.Cache
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Project

  def fetch(%Project{} = project, exports, module, function) do
    case exported?(project, exports, module, function) do
      true -> call(project, exports, module, function)
      false -> :error
    end
  end

  def fetch_by_name(%Project{} = project, module, name) when is_binary(name) do
    with {:ok, %{functions: functions}} <- ModuleRegistry.module_exports(project, module),
         {function, 0} <- Enum.find(functions, &exported_as?(&1, name)) do
      call(project, nil, module, function)
    else
      _ -> :error
    end
  end

  def function_options(%Project{} = project, module, name, arity, argument_index) do
    docs =
      Cache.fetch(project, __MODULE__, {:docs, module}, fn ->
        case EngineApi.call(project, Code, :fetch_docs, [module]) do
          {:docs_v1, _, _, _, _, _, _} = docs -> docs
          _ -> :error
        end
      end)

    find_function_options(docs, name, arity, argument_index)
  end

  def aliases(_project, %{aliases: aliases}) when map_size(aliases) > 0, do: aliases

  def aliases(%Project{} = project, %{alias_module: module, alias_function: function}) do
    case fetch_aliases(project, module, function) do
      {:ok, aliases} -> aliases
      :error -> %{}
    end
  end

  def aliases(_project, _type), do: %{}

  defp fetch_aliases(project, module, function) do
    result =
      case fetch(project, nil, module, function) do
        :error when function == :builtins -> fetch(project, nil, module, :short_names)
        result -> result
      end

    case result do
      {:ok, aliases} when is_list(aliases) ->
        {:ok,
         Map.new(
           for {name, implementation} <- aliases,
               is_atom(name) and is_atom(implementation),
               do: {to_string(name), Atom.to_string(implementation)}
         )}

      _ ->
        :error
    end
  end

  defp call(project, nil, module, function) do
    Cache.fetch(project, __MODULE__, {module, function}, fn ->
      {:ok, EngineApi.call(project, module, function, [])}
    end)
  end

  defp call(project, _exports, module, function) do
    {:ok, EngineApi.call(project, module, function, [])}
  end

  defp exported_as?({function, 0}, name), do: Atom.to_string(function) == name
  defp exported_as?(_export, _name), do: false

  defp exported?(_project, exports, _module, function) when is_list(exports),
    do: {Atom.to_string(function), 0} in exports

  defp exported?(project, nil, module, function) do
    case ModuleRegistry.module_exports(project, module) do
      {:ok, %{functions: functions}} -> {function, 0} in functions
      :error -> false
    end
  end

  defp find_function_options({:docs_v1, _, _, _, _, _, entries}, name, arity, argument_index) do
    Enum.find_value(entries, :error, fn
      {{kind, ^name, declared_arity}, _, _, _, metadata} when kind in [:function, :macro] ->
        defaults = Map.get(metadata, :defaults, 0)

        if arity >= declared_arity - defaults and arity <= declared_arity do
          Enum.find_value(Map.get(metadata, :spark_opts, []), fn
            {^argument_index, schema} -> {:ok, schema}
            _ -> nil
          end)
        end

      _ ->
        nil
    end)
  end

  defp find_function_options(_docs, _name, _arity, _argument_index), do: :error
end
