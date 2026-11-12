defmodule Expert.Search.Indexer.Beams do
  import Forge.Document.Line

  alias Expert.Integrations
  alias Expert.Progress
  alias Expert.Search.Indexer.BeamFile
  alias Expert.Search.Indexer.ETF
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Subject
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  @beam_index_concurrency 16
  @beam_chunk_size 24

  def stream(paths, opts \\ []) when is_list(paths) do
    paths
    |> result_chunks(opts)
    |> Stream.flat_map(& &1)
  end

  defp result_chunks([], _opts), do: Stream.concat([])

  defp result_chunks(paths, opts) do
    total = length(paths)

    paths
    |> Enum.chunk_every(@beam_chunk_size)
    |> Task.async_stream(&{length(&1), index_beam_chunk(stat_beams(&1), opts)},
      max_concurrency: @beam_index_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.transform(
      fn -> start_progress("Indexing dependencies metadata") end,
      fn task_result, progress ->
        {count, items} = task_result!(task_result)

        {[items], report_progress(progress, count, total, "Indexing dependencies")}
      end,
      &complete_progress/1
    )
  end

  @doc """
  Returns the public function and macro definitions of a BEAM's module, as the
  index would store them, without indexing it.
  """
  @spec definitions(Path.t()) :: [Entry.t()]
  def definitions(beam_path) do
    with {:ok, beam} <- Expert.File.read(beam_path),
         {:ok, module, exports, debug_metadata} <- BeamFile.read(beam) do
      metadata =
        case debug_metadata do
          {:ok, metadata} -> metadata
          :error -> erlang_metadata(beam, module, exports)
        end

      context = %{
        app: nil,
        module: Subject.module(module),
        root_block: Block.root(),
        source_path: beam_path
      }

      public_definition_entries(metadata, context)
    else
      _ -> []
    end
  end

  # Convert Erlang abstract code to the Elixir debug metadata shape used below.
  defp erlang_metadata(beam, module, exports) do
    clauses =
      with {:ok, chunk} <- BeamFile.chunk(beam, "Dbgi"),
           {:ok, {"debug_info_v1", "erl_abstract_code", {forms, _options}}} when is_list(forms) <-
             ETF.decode(chunk) do
        for {"function", _anno, name, arity, [{"clause", _, patterns, _, _} | _]} <- forms,
            into: %{},
            do: {{name, arity}, [{[], Enum.map(patterns, &erlang_argument/1), [], nil}]}
      else
        _ -> %{}
      end

    definitions =
      for {name, _arity} = export <- exports,
          name not in ["module_info", "behaviour_info"],
          do: {export, "def", [], Map.get(clauses, export, [])}

    %{"module" => module, "definitions" => definitions}
  end

  defp erlang_argument({"var", _anno, name}) do
    {name |> String.trim_leading("_") |> Macro.underscore(), [], nil}
  end

  defp erlang_argument({"match", _anno, left, right}) do
    case erlang_argument(left) do
      {"", [], nil} -> erlang_argument(right)
      argument -> argument
    end
  end

  defp erlang_argument(_pattern), do: {"", [], nil}

  @doc """
  Reads completion metadata from a BEAM.

  The metadata includes types, callbacks, struct fields, behaviours, and
  macro-generated definitions.
  """
  @spec read_module(Path.t()) :: {:ok, map()} | :error
  def read_module(beam_path) do
    with {:ok, beam} <- Expert.File.read(beam_path),
         {:ok, module, _exports, debug_metadata} <- BeamFile.read(beam) do
      metadata =
        case debug_metadata do
          {:ok, metadata} -> metadata
          :error -> %{}
        end

      forms = typespec_forms(beam)
      types = types(forms)

      {:ok,
       %{
         types: types,
         callbacks: callbacks(forms),
         struct_fields: struct_fields(metadata, types),
         behaviours: behaviours(beam),
         injected: injected(module, metadata)
       }}
    else
      _ -> :error
    end
  end

  @doc """
  Reads the first paragraph of a BEAM's module documentation.
  """
  @spec module_summary(Path.t()) :: String.t() | nil
  def module_summary(beam_path) do
    with {:ok, beam} <- Expert.File.read(beam_path),
         {:ok, {"docs_v1", _anno, _language, _format, moduledoc, _meta, _entries}} <- docs(beam) do
      summary(moduledoc)
    else
      _ -> nil
    end
  end

  @doc """
  Reads the summary and spec of one of a BEAM's functions or macros.
  """
  @spec function_docs(Path.t(), String.t(), String.t(), arity()) ::
          %{summary: String.t() | nil, spec: String.t() | nil}
  def function_docs(beam_path, kind, name, arity) do
    case Expert.File.read(beam_path) do
      {:ok, beam} ->
        summary =
          with {:ok, {"docs_v1", _, _, _, _, _, entries}} <- docs(beam),
               {_key, _anno, _signature, doc, _meta} <-
                 Enum.find(entries, &documents?(&1, kind, name, arity)) do
            summary(doc)
          else
            _ -> nil
          end

        spec_name = if kind == "macro", do: "MACRO-" <> name, else: name
        spec_arity = if kind == "macro", do: arity + 1, else: arity

        spec =
          Enum.find_value(typespec_forms(beam), fn
            {"attribute", _, "spec", {{^spec_name, ^spec_arity}, [form | _]}} ->
              spec_string(name, form)

            _form ->
              nil
          end)

        %{summary: summary, spec: spec}

      _error ->
        %{summary: nil, spec: nil}
    end
  end

  defp docs(beam) do
    with {:ok, chunk} <- BeamFile.chunk(beam, "Docs"), do: ETF.decode(chunk)
  end

  # One full-arity documentation entry covers every default-argument arity.
  defp documents?({{kind, name, arity}, _anno, _signature, _doc, meta}, kind, name, wanted) do
    defaults = if is_map(meta), do: Map.get(meta, "defaults", 0), else: 0
    wanted in (arity - defaults)..arity//1
  end

  defp documents?(_entry, _kind, _name, _arity), do: false

  defp summary(%{"en" => doc}) when is_binary(doc) do
    doc |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> String.trim()
  end

  defp summary(_doc), do: nil

  defp typespec_forms(beam) do
    with {:ok, chunk} <- BeamFile.chunk(beam, "Dbgi"),
         {:ok, {"debug_info_v1", backend, data}} <- ETF.decode(chunk) do
      case {backend, data} do
        {"elixir_erl", {"elixir_v1", _metadata, specs}} when is_list(specs) -> specs
        {"erl_abstract_code", {forms, _options}} when is_list(forms) -> forms
        _other -> []
      end
    else
      _ -> []
    end
  end

  defp behaviours(beam) do
    with {:ok, chunk} <- BeamFile.chunk(beam, "Attr"),
         {:ok, attributes} when is_list(attributes) <- ETF.decode(chunk) do
      for {"behaviour", modules} <- attributes, module <- modules, do: Subject.module(module)
    else
      _ -> []
    end
  end

  defp types(forms) do
    for {"attribute", _anno, kind, {name, definition, variables}} <- forms,
        kind in ["type", "opaque", "typep"] do
      arguments = Enum.map(variables, &type_string/1)

      %{
        kind: String.to_existing_atom(kind),
        name: name,
        arity: length(variables),
        arguments: arguments,
        summary: nil,
        spec: "#{name}(#{Enum.join(arguments, ", ")}) :: #{type_string(definition)}",
        definition: definition,
        metadata: %{}
      }
    end
  end

  defp callbacks(forms) do
    optional =
      for {"attribute", _anno, "optional_callbacks", callbacks} <- forms,
          callback <- callbacks,
          do: callback

    for {"attribute", _anno, "callback", {{name, arity} = callback, [form | _]}} <- forms do
      {kind, name, arity} =
        case name do
          "MACRO-" <> macro -> {:macrocallback, macro, arity - 1}
          _function -> {:callback, name, arity}
        end

      %{
        kind: kind,
        name: name,
        arity: arity,
        arguments: parameter_names(form, arity),
        summary: nil,
        spec: spec_string(name, form),
        metadata: %{optional: callback in optional}
      }
    end
  end

  # The `t` type supplies field types when the struct defines it.
  defp struct_fields(%{"struct" => fields}, types) when is_list(fields) do
    field_types =
      case Enum.find(types, &(&1.name == "t" and &1.arity == 0)) do
        %{definition: {"type", _, "map", map_fields}} when is_list(map_fields) ->
          for {"type", _, "map_field_exact", [{"atom", _, field}, type]} <- map_fields,
              into: %{},
              do: {field, type_string(type)}

        _no_t ->
          %{}
      end

    for %{"field" => field} <- fields, do: {field, Map.get(field_types, field)}
  end

  defp struct_fields(_metadata, _types), do: nil

  # Macro-generated definitions name the source macro module as their context.
  # Contexts from the current module and Kernel represent compiler-generated
  # clauses rather than overridable functions.
  defp injected(module, %{"definitions" => definitions}) do
    for {{name, arity}, kind, meta, clauses} <- definitions,
        kind in ["def", "defmacro"],
        context = meta(meta, "context"),
        is_binary(context),
        context not in [module, "Elixir.Kernel"],
        String.starts_with?(context, "Elixir.") do
      %{
        kind: if(kind == "def", do: :function, else: :macro),
        name: name,
        arity: arity,
        arguments: argument_names(clauses, [], arity),
        summary: nil,
        spec: "",
        metadata: %{context: Subject.module(context)}
      }
    end
  end

  defp injected(_module, _metadata), do: []

  defp spec_string(name, {"type", _, "bounded_fun", [function, _constraints]}),
    do: spec_string(name, function)

  defp spec_string(name, {"type", _, "fun", [{"type", _, "product", parameters}, result]}) do
    "#{name}(#{Enum.map_join(parameters, ", ", &type_string/1)}) :: #{type_string(result)}"
  end

  defp spec_string(_name, _form), do: nil

  defp parameter_names({"type", _, "bounded_fun", [function, _constraints]}, arity),
    do: parameter_names(function, arity)

  defp parameter_names({"type", _, "fun", [{"type", _, "product", parameters}, _result]}, arity)
       when length(parameters) == arity do
    for {parameter, index} <- Enum.with_index(parameters, 1) do
      case parameter do
        {"ann_type", _, [{"var", _, name}, _type]} -> variable_name(name)
        {"var", _, name} when name != "_" -> variable_name(name)
        _type -> "arg_#{index}"
      end
    end
  end

  defp parameter_names(_form, arity), do: Enum.map(1..arity//1, &"arg_#{&1}")

  defp variable_name(name), do: name |> String.trim_leading("_") |> Macro.underscore()

  # Render decoded ETF terms without converting their strings to atoms.
  defp type_string({"ann_type", _, [{"var", _, name}, type]}),
    do: "#{variable_name(name)} :: #{type_string(type)}"

  defp type_string({"var", _, "_"}), do: "_"
  defp type_string({"var", _, name}), do: variable_name(name)
  defp type_string({"integer", _, integer}), do: Integer.to_string(integer)
  defp type_string({"atom", _, atom}), do: atom_string(atom)
  defp type_string({"op", _, operator, operand}), do: "#{operator}#{type_string(operand)}"

  defp type_string({"type", _, "range", [from, to]}),
    do: "#{type_string(from)}..#{type_string(to)}"

  defp type_string({"type", _, "nil", []}), do: "[]"
  defp type_string({"type", _, "binary", [{"integer", _, 0}, {"integer", _, 0}]}), do: "binary()"
  defp type_string({"type", _, "union", types}), do: Enum.map_join(types, " | ", &type_string/1)
  defp type_string({"type", _, "list", [type]}), do: "[#{type_string(type)}]"
  defp type_string({"type", _, "tuple", "any"}), do: "tuple()"

  defp type_string({"type", _, "tuple", types}),
    do: "{#{Enum.map_join(types, ", ", &type_string/1)}}"

  defp type_string({"type", _, "map", "any"}), do: "map()"
  defp type_string({"type", _, "map", fields}), do: map_string(fields)

  defp type_string({"type", _, "fun", [{"type", _, "product", parameters}, result]}),
    do: "(#{Enum.map_join(parameters, ", ", &type_string/1)} -> #{type_string(result)})"

  defp type_string({"type", _, "fun", []}), do: "function()"

  defp type_string({"type", _, name, arguments}) when is_list(arguments),
    do: "#{name}(#{Enum.map_join(arguments, ", ", &type_string/1)})"

  defp type_string({"user_type", _, name, arguments}),
    do: "#{name}(#{Enum.map_join(arguments, ", ", &type_string/1)})"

  defp type_string({"remote_type", _, [{"atom", _, module}, {"atom", _, name}, arguments]}),
    do: "#{Subject.module(module)}.#{name}(#{Enum.map_join(arguments, ", ", &type_string/1)})"

  defp type_string(_form), do: "term()"

  defp map_string(fields) do
    {struct, fields} =
      Enum.split_with(
        fields,
        &match?({"type", _, "map_field_exact", [{"atom", _, "__struct__"}, _]}, &1)
      )

    pairs =
      Enum.map_join(fields, ", ", fn
        {"type", _, "map_field_exact", [{"atom", _, key}, value]} ->
          "#{key}: #{type_string(value)}"

        {"type", _, kind, [key, value]} ->
          "#{field_key(kind)}(#{type_string(key)}) => #{type_string(value)}"

        _field ->
          "term() => term()"
      end)

    case struct do
      [{"type", _, _, [_key, {"atom", _, module}]}] -> "%#{Subject.module(module)}{#{pairs}}"
      _plain_map -> "%{#{pairs}}"
    end
  end

  defp field_key("map_field_exact"), do: "required"
  defp field_key(_assoc), do: "optional"

  defp atom_string(atom) when atom in [nil, true, false], do: inspect(atom)
  defp atom_string("Elixir." <> _ = module), do: Subject.module(module)
  defp atom_string(atom), do: ":" <> atom

  def extract_definitions_from_binary(beam, source_path)
      when is_binary(beam) and is_binary(source_path) do
    with {:ok, _module, _exports, {:ok, metadata}} <- BeamFile.read(beam) do
      metadata = Map.put(metadata, "file", Forge.Path.native(source_path))

      entries =
        metadata
        |> entries_from_metadata(
          source_lines(source_path, [metadata |> metadata_position() |> elem(0)])
        )
        |> Enum.filter(&definition?/1)

      {:ok, entries}
    end
  end

  defp stat_beams(paths) do
    for path <- paths, {:ok, %File.Stat{} = stat} <- [Expert.File.stat(path)], do: {path, stat}
  end

  defp index_beam_chunk(beams, opts) do
    {results, modules} =
      beams
      |> Enum.map(&metadata_from_beam(&1, opts))
      |> Enum.unzip()

    register_modules(opts[:project], modules)

    {entries, manifest_entries} =
      results
      |> List.flatten()
      |> entries_and_manifest_entries(opts)

    [{entries, manifest_entries}]
  end

  defp register_modules(nil, _modules), do: :ok

  defp register_modules(project, modules) do
    modules
    |> Enum.reject(&is_nil/1)
    |> then(&ModuleRegistry.put_all(project, &1))
  end

  defp entries_and_manifest_entries(results, opts) do
    {indexed_results, skipped_results} = Enum.split_with(results, &indexed_result?/1)
    entries = entries_from_indexed_results(indexed_results, opts)
    manifest_entries = manifest_entries_from_results(indexed_results ++ skipped_results)

    {entries, manifest_entries}
  end

  defp indexed_result?(
         {:indexed, _source_path, _metadata, _integration_entries, _manifest_entry}
       ),
       do: true

  defp indexed_result?(_result), do: false

  defp task_result!({:ok, result}), do: result

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp start_progress(title) do
    token =
      case Progress.begin(title, percentage: 0) do
        {:ok, token} -> token
        {:error, :rejected} -> nil
      end

    {token, 0, System.monotonic_time(:millisecond)}
  end

  # Clients only show the percentage, and one report per file reaches them as
  # one notification per file.
  defp report_progress({token, current, start_time}, size, total, message) do
    previous = percentage(current, total)
    current = current + size
    percentage = percentage(current, total)

    if token && percentage != previous do
      Progress.report(token, message: message, percentage: percentage)
    end

    {token, current, start_time}
  end

  defp percentage(current, total), do: min(100, div(current * 100, total))

  defp complete_progress({token, _current, start_time}) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if token do
      Progress.complete(token, message: "Completed in #{format_duration(elapsed)}")
    end
  end

  defp manifest_entries_from_results(results) do
    Enum.map(results, fn
      {:indexed, _source_path, _metadata, _integration_entries, manifest_entry} -> manifest_entry
      {:skipped, manifest_entry} -> manifest_entry
    end)
  end

  defp entries_from_indexed_results([], _opts), do: []

  defp entries_from_indexed_results(results, opts) do
    source_lines_by_path = source_lines_by_path(results)

    results
    |> Enum.group_by(fn
      {:indexed, source_path, _metadata, _integration_entries, _manifest_entry} -> source_path
    end)
    |> Enum.flat_map(fn {source_path, results} ->
      entries_from_group(source_path, results, source_lines_by_path, opts)
    end)
  end

  defp entries_from_group(source_path, results, source_lines_by_path, opts) do
    entries =
      Enum.flat_map(results, fn
        {:indexed, _source_path, metadata, integration_entries, manifest_entry} ->
          entries_from_metadata(
            metadata,
            Map.get(source_lines_by_path, source_path, %{}),
            application(manifest_entry, opts)
          ) ++ integration_entries
      end)

    [Entry.block_structure(source_path, %{root: %{}}) | entries]
  end

  defp application(manifest_entry, opts) do
    applications = Keyword.get(opts, :applications, %{})
    Map.get(applications, Path.dirname(manifest_entry.input_path))
  end

  defp metadata_from_beam({beam_path, beam_stat}, opts) do
    application = Map.get(Keyword.get(opts, :applications, %{}), Path.dirname(beam_path))

    with {:ok, beam} <- Expert.File.read(beam_path),
         {:ok, module, exports, debug_metadata_result} <- BeamFile.read(beam) do
      results =
        case debug_metadata_result do
          {:ok, metadata} ->
            metadata_result_from_beam(beam_path, beam_stat, beam, exports, metadata, opts)

          :error ->
            skipped_result_from_beam(beam_path, beam_stat, nil, nil)
        end

      {results, {module, beam_path, application, exports}}
    else
      _ -> {skipped_result_from_beam(beam_path, beam_stat, nil, nil), nil}
    end
  end

  defp metadata_result_from_beam(beam_path, beam_stat, beam, exports, metadata, opts) do
    metadata =
      case Map.get(metadata, "file") do
        path when is_binary(path) -> Map.put(metadata, "file", Forge.Path.native(path))
        _ -> metadata
      end

    source_path = Map.get(metadata, "file")
    source_stat_result = stat_source(source_path)

    case source_stat_result do
      {:ok, _source_stat} ->
        {:ok, manifest_entry} =
          Manifest.Entry.beam(beam_path, source_path, beam_stat, source_stat_result)

        integration_entries =
          integration_entries(beam, exports, metadata, source_path, opts[:project])

        [{:indexed, source_path, metadata, integration_entries, manifest_entry}]

      :error ->
        skipped_result_from_beam(
          beam_path,
          beam_stat,
          source_path,
          source_stat_result
        )
    end
  end

  defp integration_entries(_beam, _exports, _metadata, _source_path, nil), do: []

  defp integration_entries(beam, exports, metadata, source_path, project) do
    Integrations.index_beam(project, beam, exports, metadata, source_path)
  end

  defp stat_source(source_path) when is_binary(source_path) do
    case Expert.File.stat(source_path) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp stat_source(_source_path), do: :error

  defp skipped_result_from_beam(
         beam_path,
         beam_stat,
         source_path,
         source_stat_result
       ) do
    {:ok, manifest_entry} =
      Manifest.Entry.skipped_beam(
        beam_path,
        source_path,
        beam_stat,
        source_stat_result
      )

    [{:skipped, manifest_entry}]
  end

  defp entries_from_metadata(metadata, source_lines, app \\ nil) do
    context = entry_context(metadata, app)

    module_entries(metadata, context, module_range(metadata, source_lines)) ++
      public_definition_entries(metadata, context)
  end

  defp entry_context(metadata, app) do
    %{
      app: app,
      module: metadata |> Map.fetch!("module") |> Subject.module(),
      root_block: Block.root(),
      source_path: Map.fetch!(metadata, "file")
    }
  end

  defp module_entries(metadata, context, module_range) do
    case protocol_implementation(metadata) do
      {:ok, protocol} ->
        [
          module_definition(context, :module, module_range),
          protocol_implementation_definition(context, protocol, module_range)
        ]

      :error ->
        case Map.get(metadata, "struct") do
          nil ->
            [module_definition(context, module_type(metadata), module_range)]

          _struct ->
            [
              module_definition(context, module_type(metadata), module_range),
              module_definition(context, :struct, module_range)
            ]
        end
    end
  end

  defp module_definition(context, type, range) do
    Entry.definition(
      context.source_path,
      context.root_block,
      context.module,
      type,
      range,
      context.app
    )
  end

  defp protocol_implementation_definition(context, protocol, range) do
    Entry.definition(
      context.source_path,
      context.root_block,
      Subject.module(protocol),
      {:protocol, :implementation},
      range,
      context.app
    )
  end

  defp public_definition_entries(metadata, context) do
    definitions = Map.get(metadata, "definitions", [])
    protocol_callbacks = protocol_callbacks(metadata)
    protocol_definition? = module_type(metadata) == {:protocol, :definition}
    delegate_specs = delegate_specs_from_metadata(metadata)
    default_wrappers = default_wrapper_identities(definitions)

    context =
      context
      |> Map.put(:defaults, default_positions(definitions))
      |> Map.put(:deprecated, metadata |> Map.get("deprecated", []) |> Map.new())

    Enum.flat_map(
      definitions,
      &public_definition_entries(
        &1,
        context,
        protocol_callbacks,
        protocol_definition?,
        delegate_specs,
        default_wrappers
      )
    )
  end

  defp public_definition_entries(
         {{name, arity}, definition, metadata, clauses},
         context,
         protocol_callbacks,
         protocol_definition?,
         delegate_specs,
         default_wrappers
       )
       when definition in ["def", "defmacro"] do
    cond do
      default_wrapper?(name, arity, definition, clauses, default_wrappers) ->
        []

      meta(metadata, "generated", false) and not meta?(metadata, "context") ->
        []

      true ->
        name
        |> public_arities(
          arity,
          meta(metadata, "defaults", 0),
          metadata,
          protocol_callbacks,
          protocol_definition?
        )
        |> Enum.flat_map(fn public_arity ->
          context
          |> public_definition_entries(
            name,
            public_arity,
            definition,
            metadata,
            delegate_specs,
            MapSet.member?(protocol_callbacks, {name, public_arity})
          )
          |> Enum.map(
            &put_completion_metadata(&1, {name, definition, clauses}, public_arity, context)
          )
        end)
    end
  end

  defp public_definition_entries(
         _definition,
         _context,
         _protocol_callbacks,
         _protocol_definition?,
         _delegate_specs,
         _default_wrappers
       ),
       do: []

  defp put_completion_metadata(entry, {name, definition, clauses}, arity, context) do
    defaults = Map.get(context.defaults, {name, definition}, [])

    metadata =
      case Map.fetch(context.deprecated, {name, arity}) do
        {:ok, reason} -> %{deprecated: reason}
        :error -> %{}
      end

    metadata = Map.put(metadata, :arguments, argument_names(clauses, defaults, arity))
    Entry.put_metadata(entry, Map.merge(entry.metadata || %{}, metadata))
  end

  # Default wrappers call the full definition through `super`. Non-variable
  # arguments mark the default positions.
  defp default_positions(definitions) do
    for {{name, _arity}, definition, _metadata, [{_meta, args, [], {"super", _, call_args}} | _]} <-
          definitions,
        definition in ["def", "defmacro"],
        reduce: %{} do
      positions ->
        own = for {var, _, context} when is_binary(var) and not is_list(context) <- args, do: var

        filled =
          for {arg, index} <- Enum.with_index(call_args), not own_variable?(arg, own), do: index

        Map.update(
          positions,
          {name, definition},
          filled,
          &Enum.max_by([&1, filled], fn p -> length(p) end)
        )
    end
  end

  defp own_variable?({var, _, context}, own) when not is_list(context), do: var in own
  defp own_variable?(_arg, _own), do: false

  # Elixir adds default arguments from left to right as arity increases.
  defp argument_names([{_meta, args, _guards, _body} | _], defaults, arity) do
    kept = arity - (length(args) - length(defaults))

    args
    |> Enum.with_index()
    |> Enum.reduce({[], kept}, fn {arg, index}, {names, kept} ->
      cond do
        index not in defaults -> {[argument_name(arg, index) | names], kept}
        kept > 0 -> {[argument_name(arg, index) | names], kept - 1}
        true -> {names, kept}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp argument_names(_clauses, _defaults, arity), do: Enum.map(1..arity//1, &"arg_#{&1}")

  defp argument_name({name, _, context}, _index)
       when is_binary(name) and name != "" and not is_list(context),
       do: name

  defp argument_name({"=", _, [left, right]}, index) do
    case {argument_name(left, index), argument_name(right, index)} do
      {"arg_" <> _, name} -> name
      {name, _right} -> name
    end
  end

  defp argument_name(_pattern, index), do: "arg_#{index + 1}"

  defp default_wrapper_identities(definitions) do
    definitions
    |> Enum.flat_map(fn
      {{name, arity}, definition, metadata, _clauses} when definition in ["def", "defmacro"] ->
        case meta(metadata, "defaults", 0) do
          defaults when defaults > 0 ->
            for wrapper_arity <- (arity - defaults)..(arity - 1),
                do: {name, wrapper_arity, definition}

          _defaults ->
            []
        end

      _definition ->
        []
    end)
    |> MapSet.new()
  end

  defp default_wrapper?(name, arity, definition, clauses, default_wrappers) do
    MapSet.member?(default_wrappers, {name, arity, definition}) and
      default_wrapper_clauses?(clauses, definition, name)
  end

  defp default_wrapper_clauses?([_clause | _rest] = clauses, definition, name) do
    Enum.all?(clauses, &default_wrapper_clause?(&1, definition, name))
  end

  defp default_wrapper_clauses?(_clauses, _definition, _name), do: false

  defp default_wrapper_clause?(
         {_metadata, _args, [], {"super", metadata, _defaults}},
         definition,
         name
       ) do
    meta(metadata, "super") == {definition, name}
  end

  defp default_wrapper_clause?(_clause, _definition, _name), do: false

  defp public_definition_entries(
         context,
         name,
         arity,
         definition,
         metadata,
         delegate_specs,
         protocol_callback?
       ) do
    case Map.get(delegate_specs, {name, arity}) do
      nil ->
        [
          public_definition_entry(
            context,
            name,
            arity,
            definition,
            metadata,
            protocol_callback?
          )
        ]

      delegate_spec ->
        [delegate_definition_entry(context, name, arity, delegate_spec)]
    end
  end

  defp public_definition_entry(
         context,
         name,
         arity,
         definition,
         metadata,
         protocol_callback?
       ) do
    type = if definition == "def", do: {:function, :public}, else: {:macro, :public}

    entry =
      Entry.definition(
        context.source_path,
        context.root_block,
        Subject.mfa(context.module, name, arity),
        type,
        definition_range(metadata, name),
        context.app
      )

    with macro_context when is_binary(macro_context) <- meta(metadata, "context"),
         false <- protocol_callback?,
         macro_module = Subject.module(macro_context),
         true <- macro_module != context.module do
      Entry.put_metadata(entry, %{
        original_mfa: Subject.mfa(macro_module, name, arity),
        via: :use
      })
    else
      _ -> entry
    end
  end

  defp delegate_definition_entry(context, name, arity, delegate_spec) do
    context.source_path
    |> Entry.definition(
      context.root_block,
      Subject.mfa(context.module, name, arity),
      {:function, :delegate},
      delegate_spec.range,
      context.app
    )
    |> Entry.put_metadata(%{
      original_mfa: Subject.mfa(delegate_spec.module, delegate_spec.name, delegate_spec.arity)
    })
  end

  defp delegate_specs_from_metadata(metadata) do
    metadata
    |> Map.get("definitions", [])
    |> Enum.flat_map(&delegate_specs/1)
    |> Map.new()
  end

  defp delegate_specs({{name, arity}, "def", metadata, clauses}) do
    with true <- delegate_metadata?(metadata),
         {:ok, module, target_name, target_arity} <- delegate_target(clauses) do
      defaults = meta(metadata, "defaults", 0)

      spec = %{
        module: module,
        name: target_name,
        arity: target_arity,
        range: definition_range(metadata, name)
      }

      for local_arity <- (arity - defaults)..arity do
        {{name, local_arity}, spec}
      end
    else
      _ -> []
    end
  end

  defp delegate_specs(_definition), do: []

  defp delegate_metadata?(metadata) do
    meta?(metadata, "line") and not meta?(metadata, "column") and not meta?(metadata, "context")
  end

  defp delegate_target([{_metadata, args, [], body}]) do
    with {{".", _dot_metadata, [module, name]}, _call_metadata, call_args} <- body,
         true <- is_binary(module),
         true <- is_binary(name),
         true <- same_variables?(args, call_args) do
      {:ok, Subject.module(module), name, length(call_args)}
    else
      _ -> :error
    end
  end

  defp delegate_target(_clauses), do: :error

  defp same_variables?(args, call_args) when length(args) == length(call_args) do
    args
    |> Enum.zip(call_args)
    |> Enum.all?(fn {arg, call_arg} -> variable_identity(arg) == variable_identity(call_arg) end)
  end

  defp same_variables?(_args, _call_args), do: false

  defp variable_identity({name, metadata, context}) when is_binary(name) and is_list(metadata) do
    {name, meta(metadata, "version"), context}
  end

  defp variable_identity(_ast), do: :error

  defp module_type(%{"attributes" => attributes}) do
    if meta?(attributes, "__protocol__"), do: {:protocol, :definition}, else: :module
  end

  defp module_type(_), do: :module

  defp protocol_implementation(%{"attributes" => attributes}) do
    with impl when is_list(impl) <- meta(attributes, "__impl__"),
         protocol when is_binary(protocol) <- meta(impl, "protocol") do
      {:ok, protocol}
    else
      _ -> :error
    end
  end

  defp protocol_implementation(_metadata), do: :error

  defp protocol_callbacks(metadata) do
    metadata
    |> Map.get("definitions", [])
    |> Enum.find_value([], fn
      {{"__protocol__", 1}, "def", _definition_metadata, clauses} ->
        protocol_callback_clauses(clauses)

      _definition ->
        nil
    end)
    |> MapSet.new()
  end

  defp protocol_callback_clauses(clauses) do
    clauses
    |> Enum.find_value([], fn
      {_metadata, ["functions"], [], functions} when is_list(functions) -> functions
      _clause -> nil
    end)
    |> Enum.flat_map(fn
      {name, arity} when is_binary(name) and is_integer(arity) -> [{name, arity}]
      _function -> []
    end)
  end

  defp public_arities(
         name,
         arity,
         defaults,
         definition_metadata,
         protocol_callbacks,
         protocol_definition?
       ) do
    arities = Enum.to_list((arity - defaults)..arity)

    if protocol_definition? and meta?(definition_metadata, "context") do
      Enum.filter(arities, &MapSet.member?(protocol_callbacks, {name, &1}))
    else
      arities
    end
  end

  defp definition_range(metadata, name) do
    range(meta(metadata, "line", 1), meta(metadata, "column", 1), String.length(name))
  end

  # BEAM debug metadata stores nested modules under their expanded names, but the
  # source often only contains the visible suffix (`defmodule Child`). Scan the
  # definition line for the source spelling before falling back to compiler data.
  defp module_range(metadata, source_lines) do
    {line, fallback_column} = metadata_position(metadata)
    module_name = metadata |> Map.fetch!("module") |> Subject.module()

    fallback_span = {fallback_column, String.length(module_name)}

    {column, length} =
      case source_definition_span(metadata, source_lines, line, module_name) do
        {:ok, span} -> span
        :error -> fallback_span
      end

    range(line, column, length)
  end

  defp source_definition_span(metadata, source_lines, line, module_name) do
    case Map.get(source_lines, line) do
      line_text when is_binary(line_text) -> definition_span(metadata, line_text, module_name)
      _ -> :error
    end
  end

  defp definition_span(metadata, line_text, module_name) do
    if protocol_implementation?(metadata) do
      defimpl_span(line_text)
    else
      module_definition_name_span(line_text, module_name)
    end
  end

  defp defimpl_span(line_text) do
    with {start_byte, _length} <- :binary.match(line_text, "defimpl"),
         {:ok, end_byte} <- defimpl_end_byte(line_text, start_byte) do
      byte_span_to_column_span(line_text, start_byte, end_byte - start_byte)
    else
      _ -> :error
    end
  end

  defp defimpl_end_byte(line_text, start_byte) do
    rest = binary_part(line_text, start_byte, byte_size(line_text) - start_byte)

    case :binary.match(rest, " do") do
      {do_byte, do_length} -> {:ok, start_byte + do_byte + do_length}
      :nomatch -> {:ok, line_text |> String.trim_trailing() |> byte_size()}
    end
  end

  defp protocol_implementation?(metadata) do
    match?({:ok, _protocol}, protocol_implementation(metadata))
  end

  defp module_definition_name_span(line_text, module_name) do
    with {:ok, search_start_byte} <- module_name_search_start(line_text),
         {:ok, start_byte, length} <-
           module_name_match(line_text, search_start_byte, module_name) do
      byte_span_to_column_span(line_text, start_byte, length)
    end
  end

  defp module_name_search_start(line_text) do
    ["defmodule", "defprotocol"]
    |> Enum.flat_map(&:binary.matches(line_text, &1))
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {byte_index, length} -> {:ok, byte_index + length}
      nil -> :error
    end
  end

  defp module_name_match(line_text, search_start, module_name) do
    line_text
    |> module_name_suffixes(module_name)
    |> Enum.find_value(:error, fn candidate ->
      match =
        line_text
        |> :binary.matches(candidate, scope: {search_start, byte_size(line_text) - search_start})
        |> Enum.find(fn {byte_index, length} ->
          module_name_boundary?(line_text, byte_index, length)
        end)

      case match do
        {byte_index, length} -> {:ok, byte_index, length}
        nil -> false
      end
    end)
  end

  defp module_name_boundary?(line_text, byte_index, length) do
    not module_name_character_before?(line_text, byte_index) and
      not module_name_character_at?(line_text, byte_index + length)
  end

  defp module_name_character_before?(_line_text, 0), do: false

  defp module_name_character_before?(line_text, byte_index) do
    module_name_character_at?(line_text, byte_index - 1)
  end

  defp module_name_character_at?(line_text, byte_index) when byte_index >= byte_size(line_text) do
    false
  end

  defp module_name_character_at?(line_text, byte_index) do
    character = :binary.at(line_text, byte_index)

    character in ?A..?Z or character in ?a..?z or character in ?0..?9 or character in [?_, ?.]
  end

  defp module_name_suffixes(line_text, module_name) do
    segments = String.split(module_name, ".")

    suffixes =
      for index <- 0..(length(segments) - 1), do: segments |> Enum.drop(index) |> Enum.join(".")

    module_alias_suffixes = Enum.map(suffixes, &"__MODULE__.#{&1}")

    Enum.filter(module_alias_suffixes ++ suffixes, &String.contains?(line_text, &1))
  end

  defp byte_span_to_column_span(line_text, start_byte, byte_length) when byte_length > 0 do
    column = line_text |> binary_part(0, start_byte) |> String.length()
    length = line_text |> binary_part(start_byte, byte_length) |> String.length()

    {:ok, {column + 1, length}}
  end

  defp byte_span_to_column_span(_line_text, _start_byte, _byte_length), do: :error

  defp source_lines_by_path(results) do
    results
    |> Enum.group_by(
      fn {:indexed, source_path, _metadata, _integration_entries, _manifest_entry} ->
        source_path
      end,
      fn {:indexed, _source_path, metadata, _integration_entries, _manifest_entry} ->
        metadata |> metadata_position() |> elem(0)
      end
    )
    |> Map.new(fn {source_path, lines} -> {source_path, source_lines(source_path, lines)} end)
  end

  defp source_lines(source_path, lines) do
    source_lines = lines |> Enum.filter(&valid_line?/1) |> Enum.uniq() |> Enum.sort()

    read_source_lines(source_path, source_lines)
  end

  defp read_source_lines(_source_path, []), do: %{}

  defp read_source_lines(source_path, lines) do
    source_path
    |> File.stream!(:line, [])
    |> Stream.with_index(1)
    |> Enum.reduce_while({lines, %{}}, &collect_source_line/2)
    |> elem(1)
  rescue
    _ -> %{}
  end

  defp collect_source_line(_source_line, {[], lines_by_number}) do
    {:halt, {[], lines_by_number}}
  end

  defp collect_source_line({line_text, line_number}, {[next_line], lines_by_number})
       when line_number == next_line do
    {:halt, {[], Map.put(lines_by_number, line_number, line_text)}}
  end

  defp collect_source_line({line_text, line_number}, {[next_line | rest], lines_by_number})
       when line_number == next_line do
    {:cont, {rest, Map.put(lines_by_number, line_number, line_text)}}
  end

  defp collect_source_line(
         {_line_text, line_number},
         {[next_line | _rest] = lines, lines_by_number}
       )
       when line_number < next_line do
    {:cont, {lines, lines_by_number}}
  end

  defp collect_source_line(_source_line, {[_next_line | rest], lines_by_number}) do
    {:cont, {rest, lines_by_number}}
  end

  defp valid_line?(line), do: is_integer(line) and line > 0

  defp definition?(%Entry{subtype: :definition}), do: true
  defp definition?(_entry), do: false

  defp metadata_position(metadata) do
    case Map.get(metadata, "anno") || Map.get(metadata, "line") do
      {line, column} -> {line, column}
      line when is_integer(line) -> {line, 1}
      _ -> {1, 1}
    end
  end

  defp range(line, column, length) do
    end_column = column + max(length, 1)
    context_line = synthetic_line(line, end_column)

    Range.new(
      position(line, column, context_line),
      position(line, end_column, context_line)
    )
  end

  defp position(line, column, context_line) do
    # NOTE(doorgan): We need to populate `document_line_count` otherwise the LSP
    # range will end up pointing to the top of the file. We are faking it here
    # instead of actually reading the file for performance, and it seems to work
    # well despite being a hack.
    %Position{
      line: line,
      character: column,
      context_line: context_line,
      document_line_count: line,
      starting_index: 1,
      valid?: true
    }
  end

  defp synthetic_line(line_number, column) do
    line(text: String.duplicate(" ", max(column - 1, 0)), ending: "", line_number: line_number)
  end

  defp meta(metadata, key, default \\ nil) do
    case List.keyfind(metadata, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp meta?(metadata, key), do: List.keymember?(metadata, key, 0)

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
