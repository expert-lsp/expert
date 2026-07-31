defmodule Engine.Integrations.Spark.Indexer do
  @behaviour Engine.Integrations

  alias Engine.Modules
  alias Forge.Search.Indexer.Entry

  @callback_timeout 2_000
  @spark_extension Spark.Dsl.Extension

  def recognizes?(metadata) do
    attributes = Map.get(metadata, :attributes, [])
    behaviours = attribute_modules(attributes, :behaviour)

    true in attribute_values(attributes, :spark_dsl) or
      behaviours != [] or attribute_modules(attributes, :spark_is) != []
  end

  @impl Engine.Integrations
  def index(binary, metadata, source_path) do
    function_entries = function_option_entries(binary, metadata, source_path)

    if recognizes?(metadata) do
      index_module(binary, metadata, source_path) ++ function_entries
    else
      function_entries
    end
  end

  defp index_module(binary, metadata, source_path) do
    module = Map.fetch!(metadata, :module)
    attributes = Map.get(metadata, :attributes, [])
    dsl? = true in attribute_values(attributes, :spark_dsl)
    behaviours = attribute_modules(attributes, :behaviour)
    extension? = @spark_extension in behaviours
    skip_callback? = exports?(binary, :skip_in_spark_autocomplete, 0)
    constraints_callback? = exports?(binary, :constraints, 0)

    {skip?, dynamic_entries} =
      dynamic_entries(attributes, binary, module, source_path, dsl?, extension?, skip_callback?)

    constraints = constraints(binary, module, constraints_callback?)

    relation_entries(source_path, module, attributes, skip?, constraints) ++ dynamic_entries
  end

  defp dynamic_entries(_attributes, _binary, _module, _source_path, false, false, false),
    do: {false, []}

  defp dynamic_entries(attributes, binary, module, source_path, dsl?, extension?, skip_callback?) do
    run_with_timeout(
      fn ->
        loaded? = loaded_module_matches?(module, binary)
        skip? = skip_callback? and skip_in_spark_autocomplete?(module, loaded?)

        {skip?, index_entries(attributes, module, source_path, dsl?, extension?, loaded?)}
      end,
      {skip_callback?, []}
    )
  end

  defp index_entries(attributes, module, source_path, dsl?, extension?, loaded?) do
    []
    |> maybe_add(dsl?, fn -> dsl_entry(source_path, module, attributes, loaded?) end)
    |> maybe_add(extension?, fn -> extension_entry(source_path, module, loaded?) end)
    |> Enum.reject(&is_nil/1)
  end

  defp relation_entries(path, module, attributes, skip?, constraints) do
    payload =
      if constraints == [], do: %{skip?: skip?}, else: %{skip?: skip?, constraints: constraints}

    behaviour_entries =
      attributes
      |> attribute_modules(:behaviour)
      |> Enum.uniq()
      |> Enum.map(&relation_entry(path, :behaviour, &1, module, payload))

    type_entries =
      attributes
      |> attribute_modules(:spark_is)
      |> Enum.uniq()
      |> Enum.map(&relation_entry(path, :type, &1, module, %{}))

    behaviour_entries ++ type_entries
  end

  defp constraints(_binary, _module, false), do: []

  defp constraints(binary, module, true) do
    run_with_timeout(
      fn ->
        if loaded_module_matches?(module, binary),
          do: normalize_schema(module.constraints()),
          else: []
      end,
      []
    )
  end

  defp relation_entry(path, kind, target, module, payload) do
    target = module_name(target)
    module = module_name(module)

    entry = Entry.integration(path, "spark", kind, module, Map.put(payload, :module, module))
    %Entry{entry | subject: Entry.integration_subject("spark", kind, "#{target}/#{module}")}
  end

  defp dsl_entry(path, module, attributes, loaded?) do
    with {:ok, default_extension_kinds} <-
           callback_result(module, :default_extension_kinds, loaded?),
         {:ok, single_extension_kinds} <-
           callback_result(module, :single_extension_kinds, loaded?),
         {:ok, options} <- callback_result(module, :opt_schema, loaded?) do
      metadata = %{
        default_extensions:
          module
          |> callback_or_attribute(
            :default_extensions,
            attribute_modules(attributes, :spark_default_extensions),
            loaded?
          )
          |> normalize_modules(),
        default_extension_kinds: normalize_extension_kinds(default_extension_kinds),
        single_extension_kinds: normalize_names(single_extension_kinds),
        extension_kinds:
          attributes
          |> attribute_values(:spark_extension_kinds)
          |> List.flatten()
          |> normalize_names(),
        options: normalize_schema(options)
      }

      entry(path, :dsl, module, metadata)
    else
      _ -> nil
    end
  end

  defp extension_entry(path, module, loaded?) do
    with {:ok, added_extensions} <- callback_result(module, :add_extensions, loaded?),
         {:ok, sections} <- callback_result(module, :sections, loaded?),
         {:ok, patches} <- callback_result(module, :dsl_patches, loaded?) do
      metadata = %{
        added_extensions: normalize_modules(added_extensions),
        sections: normalize_sections(sections),
        patches: normalize_patches(patches)
      }

      entry(path, :extension, module, metadata)
    else
      _ -> nil
    end
  end

  defp entry(path, kind, key, metadata) do
    Entry.integration(path, "spark", kind, key, metadata)
  end

  defp function_option_entries(binary, metadata, source_path) do
    module = Map.fetch!(metadata, :module)

    case Modules.fetch_docs(binary) do
      {:ok, {:docs_v1, _, _, _, _, _, entries}} ->
        for {{kind, name, arity}, _, _, _, metadata} <- entries,
            kind in [:function, :macro],
            {argument_index, schema} <- Map.get(metadata, :spark_opts, []),
            is_integer(argument_index) and argument_index >= 0,
            callable_arity <- (arity - Map.get(metadata, :defaults, 0))..arity,
            argument_index < callable_arity do
          key = "#{Forge.Formats.mfa(module, name, callable_arity)}/#{argument_index}"
          entry(source_path, :function, key, normalize_schema(schema))
        end

      _ ->
        []
    end
  end

  defp attribute_values(attributes, name) do
    attributes
    |> Keyword.get_values(name)
    |> List.flatten()
  end

  defp attribute_modules(attributes, name) do
    attributes
    |> attribute_values(name)
    |> Enum.filter(&is_atom/1)
  end

  defp loaded_module_matches?(module, binary) do
    with {:ok, {^module, md5}} <- :beam_lib.md5(binary),
         {:module, ^module} <- Code.ensure_loaded(module) do
      module.module_info(:md5) == md5 or reload_matching_module?(module, binary, md5)
    else
      _ -> false
    end
  end

  defp reload_matching_module?(module, binary, md5) do
    with path when is_list(path) <- :code.which(module),
         {:ok, ^binary} <- File.read(List.to_string(path)),
         true <- :code.soft_purge(module),
         {:module, ^module} <- :code.load_binary(module, path, binary) do
      module.module_info(:md5) == md5
    else
      _ -> false
    end
  end

  defp callback_or_attribute(module, function, fallback, loaded?) do
    case callback(module, function, loaded?) do
      :error -> fallback
      value -> value
    end
  end

  defp callback_result(module, function, loaded?) do
    case callback(module, function, loaded?) do
      :error -> :error
      value -> {:ok, value}
    end
  end

  defp callback(_module, _function, false), do: :error

  defp callback(module, function, true) do
    if function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      :error
    end
  end

  defp exports?(binary, name, arity) do
    case :beam_lib.chunks(binary, [:exports]) do
      {:ok, {_module, [exports: exports]}} -> {name, arity} in exports
      _ -> false
    end
  end

  defp skip_in_spark_autocomplete?(_module, false), do: true

  defp skip_in_spark_autocomplete?(module, true) do
    function_exported?(module, :skip_in_spark_autocomplete, 0) and
      module.skip_in_spark_autocomplete() == true
  end

  defp run_with_timeout(fun, fallback) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _exception -> fallback
        catch
          _kind, _reason -> fallback
        end
      end)

    case Task.yield(task, @callback_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> fallback
    end
  end

  defp normalize_extension_kinds(value) when is_list(value) do
    Map.new(value, fn {kind, modules} -> {to_string(kind), normalize_modules(modules)} end)
  end

  defp normalize_extension_kinds(_), do: %{}

  defp normalize_names(:error), do: []

  defp normalize_names(value),
    do: value |> List.wrap() |> List.flatten() |> Enum.map(&to_string/1)

  defp normalize_modules(:error), do: []

  defp normalize_modules(value) do
    value
    |> List.wrap()
    |> List.flatten()
    |> Enum.filter(&is_atom/1)
    |> Enum.map(&module_name/1)
    |> Enum.uniq()
  end

  defp normalize_sections(:error), do: []

  defp normalize_sections(sections) when is_list(sections) do
    Enum.flat_map(sections, fn
      section when is_map(section) -> [normalize_section(section)]
      _ -> []
    end)
  end

  defp normalize_sections(_sections), do: []

  defp normalize_section(section) when is_map(section) do
    %{
      name: section |> Map.get(:name) |> to_string_or_empty(),
      documentation:
        section
        |> Map.get(:docs)
        |> present_or(Map.get(section, :describe))
        |> normalize_documentation(),
      snippet: normalize_snippet(Map.get(section, :snippet)),
      top_level?: Map.get(section, :top_level?, false),
      options: normalize_schema(Map.get(section, :schema, [])),
      entities: section |> Map.get(:entities, []) |> normalize_entities(),
      sections: normalize_sections(Map.get(section, :sections, []))
    }
  end

  defp normalize_entity(entity) when is_map(entity) do
    %{
      name: entity |> Map.get(:name) |> to_string_or_empty(),
      documentation:
        entity
        |> Map.get(:docs)
        |> present_or(Map.get(entity, :describe))
        |> normalize_documentation(),
      snippet: normalize_snippet(Map.get(entity, :snippet)),
      arguments: entity |> Map.get(:args, []) |> List.wrap() |> Enum.map(&normalize_argument/1),
      options: normalize_schema(Map.get(entity, :schema, [])),
      entities:
        entity
        |> Map.get(:entities, [])
        |> List.wrap()
        |> Enum.flat_map(fn
          {_group, entities} ->
            normalize_entities(entities)

          _ ->
            []
        end)
    }
  end

  defp normalize_entities(entities) when is_list(entities) do
    Enum.flat_map(entities, fn
      entity when is_map(entity) -> [normalize_entity(entity)]
      _ -> []
    end)
  end

  defp normalize_entities(_entities), do: []

  defp normalize_argument({:optional, name}), do: %{name: to_string(name), optional?: true}

  defp normalize_argument({:optional, name, default}) do
    %{name: to_string(name), optional?: true, default: normalize_literal(default)}
  end

  defp normalize_argument(name), do: %{name: to_string(name), optional?: false}

  defp normalize_patches(patches) do
    Enum.flat_map(List.wrap(patches), fn
      %{section_path: path, entity: entity} ->
        [
          %{
            section_path: Enum.map(List.wrap(path), &to_string/1),
            entity: normalize_entity(entity)
          }
        ]

      _ ->
        []
    end)
  end

  defp normalize_schema(:error), do: []

  defp normalize_schema(schema) when is_list(schema) do
    Enum.flat_map(schema, fn
      {name, config} when is_atom(name) and is_list(config) ->
        [
          %{
            name: to_string(name),
            documentation: normalize_documentation(Keyword.get(config, :doc)),
            snippet: normalize_snippet(Keyword.get(config, :snippet)),
            default: normalize_literal(Keyword.get(config, :default)),
            type:
              config
              |> Keyword.get(:type)
              |> normalize_type()
              |> with_keys(Keyword.get(config, :keys))
          }
        ]

      _ ->
        []
    end)
  end

  defp normalize_schema(_), do: []

  defp normalize_type(:boolean), do: %{kind: :boolean}
  defp normalize_type(:string), do: %{kind: :string}
  defp normalize_type(:atom), do: %{kind: :atom}
  defp normalize_type(:map), do: %{kind: :map}
  defp normalize_type(:keyword_list), do: %{kind: :keyword_list}
  defp normalize_type(:non_empty_keyword_list), do: %{kind: :keyword_list}
  defp normalize_type(:module), do: %{kind: :module}
  defp normalize_type(:mfa), do: %{kind: :mfa}

  defp normalize_type(:fun), do: %{kind: :function, arity: nil}

  defp normalize_type({:behaviour, module}) when is_atom(module),
    do: %{kind: :behaviour, behaviour: module_name(module)}

  defp normalize_type({:spark, module}) when is_atom(module),
    do: %{kind: :spark, type: module_name(module)}

  defp normalize_type({:spark_type, module, function}),
    do: normalize_type({:spark_type, module, function, []})

  defp normalize_type({:spark_type, module, function, _templates})
       when is_atom(module) and is_atom(function) do
    %{
      kind: :spark_type,
      behaviour: module_name(module),
      aliases: spark_type_aliases(module, function)
    }
  end

  defp normalize_type({:spark_behaviour, behaviour}),
    do: normalize_type({:spark_behaviour, behaviour, nil})

  defp normalize_type({:spark_behaviour, behaviour, builtins})
       when is_atom(behaviour) and (is_atom(builtins) or is_nil(builtins)) do
    %{
      kind: :spark_behaviour,
      behaviour: module_name(behaviour),
      builtins: source_module_name(builtins)
    }
  end

  defp normalize_type({:spark_function_behaviour, behaviour, function}),
    do: normalize_type({:spark_function_behaviour, behaviour, nil, function})

  defp normalize_type({:spark_function_behaviour, behaviour, builtins, {module, arity}})
       when is_atom(behaviour) and is_atom(module) and is_integer(arity) and arity >= 0 do
    %{
      kind: :spark_function_behaviour,
      behaviour: module_name(behaviour),
      builtins: source_module_name(builtins),
      function: %{module: module_name(module), arity: arity}
    }
  end

  defp normalize_type({:fun, arity}) when is_integer(arity) and arity >= 0,
    do: %{kind: :function, arity: arity}

  defp normalize_type({:fun, args}) when is_list(args),
    do: %{kind: :function, arity: length(args)}

  defp normalize_type({:fun, args, _return}) when is_list(args),
    do: %{kind: :function, arity: length(args)}

  defp normalize_type({kind, values}) when kind in [:one_of, :in] do
    %{kind: :choices, values: Enum.map(Enum.to_list(values), &choice/1)}
  end

  defp normalize_type({:literal, value}), do: %{kind: :choices, values: [choice(value)]}

  defp normalize_type({kind, type}) when kind in [:list, :wrap_list] do
    %{kind: kind, item: normalize_type(type)}
  end

  defp normalize_type({kind, schema}) when kind in [:keyword_list, :non_empty_keyword_list] do
    %{kind: :keyword_list, options: normalize_schema(schema)}
  end

  defp normalize_type({:or, types}), do: %{kind: :or, types: Enum.map(types, &normalize_type/1)}

  defp normalize_type(type), do: %{kind: :unknown, value: inspect(type)}

  defp with_keys(type, keys) do
    case normalize_schema(keys) do
      [] -> type
      options -> Map.put(type, :options, options)
    end
  end

  defp spark_type_aliases(module, function) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         callback when not is_nil(callback) <- spark_type_callback(module, function),
         aliases when is_list(aliases) <- apply(module, callback, []) do
      for {name, implementation} <- aliases,
          is_atom(name) and is_atom(implementation),
          into: %{} do
        {to_string(name), module_name(implementation)}
      end
    else
      _ -> %{}
    end
  end

  defp spark_type_callback(module, function) do
    cond do
      function_exported?(module, function, 0) -> function
      function == :builtins and function_exported?(module, :short_names, 0) -> :short_names
      true -> nil
    end
  end

  defp choice(value), do: %{label: inspect(value), insert_text: inspect(value)}

  defp normalize_literal(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp normalize_literal(value) when is_atom(value), do: %{atom: Atom.to_string(value)}
  defp normalize_literal(value) when is_list(value), do: Enum.map(value, &normalize_literal/1)

  defp normalize_literal(value) when is_tuple(value) do
    %{tuple: value |> Tuple.to_list() |> Enum.map(&normalize_literal/1)}
  end

  defp normalize_literal(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {to_string(key), normalize_literal(item)} end)
  end

  defp normalize_literal(value), do: inspect(value)

  defp normalize_documentation(value) when is_binary(value), do: value
  defp normalize_documentation(_value), do: ""

  defp normalize_snippet(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 64_000,
       do: value

  defp normalize_snippet(_value), do: nil

  defp present_or(value, fallback) when value in [nil, ""], do: fallback
  defp present_or(value, _fallback), do: value

  defp maybe_add(entries, true, fun), do: [fun.() | entries]
  defp maybe_add(entries, false, _fun), do: entries

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value), do: to_string(value)

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp source_module_name(nil), do: nil
  defp source_module_name(module), do: Forge.Formats.module(module)
end
