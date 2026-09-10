defmodule Engine.Search.Indexer.Beams do
  import Forge.Document.Line

  alias Engine.ApplicationCache
  alias Engine.Progress
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Subject
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  @beam_index_concurrency 16
  @beam_index_chunk_bytes 128 * 1024

  def index(paths) when is_list(paths) do
    {beams, total_bytes} = stat_beams(paths)

    beams
    |> index_beam_chunks(total_bytes)
    |> entries_and_manifest_entries()
  end

  def extract_definitions_from_binary(beam, source_path)
      when is_binary(beam) and is_binary(source_path) do
    with {:ok, metadata} <- debug_metadata_from_binary(beam) do
      metadata = Map.put(metadata, :file, Forge.Path.native(source_path))

      entries =
        metadata
        |> entries_from_metadata(
          source_lines(source_path, [metadata |> metadata_position() |> elem(0)])
        )
        |> Enum.filter(&definition?/1)

      {:ok, entries}
    end
  end

  def extract_definitions_from_binary(beam, source_path, module, compiler_definitions)
      when is_binary(beam) and is_binary(source_path) and is_atom(module) and
             is_list(compiler_definitions) do
    compiler_entries =
      remote_context_definition_entries(
        Forge.Path.native(source_path),
        module,
        compiler_definitions
      )

    case extract_definitions_from_binary(beam, source_path) do
      {:ok, entries} -> {:ok, entries ++ compiler_entries}
      :error when compiler_entries != [] -> {:ok, compiler_entries}
      :error -> :error
    end
  end

  defp stat_beams(paths) do
    Enum.reduce(paths, {[], 0}, fn path, {beams, total_bytes} ->
      case File.stat(path) do
        {:ok, %File.Stat{} = stat} ->
          {[{path, stat} | beams], total_bytes + stat.size}

        _ ->
          {beams, total_bytes}
      end
    end)
  end

  defp index_beam_chunks([], _total_bytes), do: []

  defp index_beam_chunks(beams, total_bytes) do
    Progress.with_tracked_progress("Indexing dependencies metadata", total_bytes, fn report ->
      start_time = System.monotonic_time(:millisecond)

      results =
        beams
        |> beam_chunks()
        |> Task.async_stream(&index_beam_chunk(&1, report),
          max_concurrency: @beam_index_concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(&task_result!/1)

      elapsed = System.monotonic_time(:millisecond) - start_time
      {:done, results, "Completed in #{format_duration(elapsed)}"}
    end)
  end

  defp beam_chunks(beams) do
    {chunks, current_chunk} =
      Enum.reduce(beams, {[], {0, []}}, fn beam, {chunks, {chunk_bytes, chunk_beams}} ->
        chunk_bytes = chunk_bytes + beam_size(beam)
        chunk_beams = [beam | chunk_beams]

        if chunk_bytes >= @beam_index_chunk_bytes do
          {[{chunk_bytes, chunk_beams} | chunks], {0, []}}
        else
          {chunks, {chunk_bytes, chunk_beams}}
        end
      end)

    case current_chunk do
      {0, []} -> chunks
      {_chunk_bytes, [_ | _]} = chunk -> [chunk | chunks]
    end
  end

  defp beam_size({_path, %File.Stat{size: size}}), do: size

  defp index_beam_chunk({chunk_bytes, beams}, report) do
    results = Enum.flat_map(beams, &metadata_from_beam/1)
    report.(message: "Indexing dependencies", add: chunk_bytes)
    results
  end

  defp entries_and_manifest_entries(results) do
    {indexed_results, skipped_results} = Enum.split_with(results, &indexed_result?/1)
    entries = entries_from_indexed_results(indexed_results)
    manifest_entries = manifest_entries_from_results(indexed_results ++ skipped_results)

    {entries, manifest_entries}
  end

  defp indexed_result?({:indexed, _source_path, _metadata, _manifest_entry}), do: true
  defp indexed_result?(_result), do: false

  defp manifest_entries_from_results(results) do
    Enum.map(results, fn
      {:indexed, _source_path, _metadata, manifest_entry} -> manifest_entry
      {:skipped, manifest_entry} -> manifest_entry
    end)
  end

  defp entries_from_indexed_results([]), do: []

  defp entries_from_indexed_results(results) do
    source_lines_by_path = source_lines_by_path(results)

    results
    |> Enum.group_by(fn {:indexed, source_path, _metadata, _manifest_entry} -> source_path end)
    |> Enum.flat_map(fn {source_path, results} ->
      entries_from_group(source_path, results, source_lines_by_path)
    end)
  end

  defp entries_from_group(source_path, results, source_lines_by_path) do
    entries =
      Enum.flat_map(results, fn {:indexed, _source_path, metadata, _manifest_entry} ->
        entries_from_metadata(metadata, Map.get(source_lines_by_path, source_path, %{}))
      end)

    [Entry.block_structure(source_path, %{root: %{}}) | entries]
  end

  defp metadata_from_beam({beam_path, beam_stat}) do
    case debug_metadata(beam_path) do
      {:ok, metadata} -> metadata_result_from_beam(beam_path, beam_stat, metadata)
      :error -> skipped_result_from_beam(beam_path, beam_stat, nil, nil)
    end
  end

  defp metadata_result_from_beam(beam_path, beam_stat, metadata) do
    source_path = Map.get(metadata, :file)
    source_stat_result = stat_source(source_path)

    case source_stat_result do
      {:ok, _source_stat} ->
        {:ok, manifest_entry} =
          Manifest.Entry.beam(beam_path, source_path, beam_stat, source_stat_result)

        [{:indexed, source_path, metadata, manifest_entry}]

      :error ->
        skipped_result_from_beam(beam_path, beam_stat, source_path, source_stat_result)
    end
  end

  defp stat_source(source_path) when is_binary(source_path) do
    case File.stat(source_path) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp stat_source(_source_path), do: :error

  defp skipped_result_from_beam(beam_path, beam_stat, source_path, source_stat_result) do
    {:ok, manifest_entry} =
      Manifest.Entry.skipped_beam(
        beam_path,
        source_path,
        beam_stat,
        source_stat_result
      )

    [{:skipped, manifest_entry}]
  end

  @doc """
  Returns the debug_info metadata chunk from the provided beam path.
  """
  # The debug-info chunk data is backend-owned and opaque. The public contract is
  # to ask the backend to decode it into the Elixir debug-info format we consume.
  def debug_metadata(beam_path) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(String.to_charlist(beam_path), [:debug_info]),
         {:ok, metadata} when is_map(metadata) <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, metadata}
    else
      _ -> :error
    end
  end

  @doc """
  Returns the debug_info metadata chunk from the provided beam binary.
  """
  def debug_metadata_from_binary(beam) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, metadata} when is_map(metadata) <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, metadata}
    else
      _ -> :error
    end
  end

  defp entries_from_metadata(metadata, source_lines) do
    context = entry_context(metadata)

    module_entries(metadata, context, module_range(metadata, source_lines)) ++
      public_definition_entries(metadata, context)
  end

  defp entry_context(metadata) do
    module = Map.fetch!(metadata, :module)

    %{
      app: ApplicationCache.application(module),
      module: module,
      root_block: Block.root(),
      source_path: Map.fetch!(metadata, :file)
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
        case Map.get(metadata, :struct) do
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
      Subject.module(context.module),
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
      ApplicationCache.application(protocol)
    )
  end

  defp public_definition_entries(metadata, context) do
    definitions = Map.get(metadata, :definitions, [])
    protocol_callbacks = protocol_callbacks(metadata)
    protocol_definition? = module_type(metadata) == {:protocol, :definition}
    delegate_specs = delegate_specs_from_metadata(metadata)
    default_wrappers = default_wrapper_identities(definitions)

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
       when definition in [:def, :defmacro] do
    cond do
      default_wrapper?(name, arity, definition, clauses, default_wrappers) ->
        []

      Keyword.get(metadata, :generated, false) and not Keyword.has_key?(metadata, :context) ->
        []

      true ->
        name
        |> public_arities(
          arity,
          Keyword.get(metadata, :defaults, 0),
          metadata,
          protocol_callbacks,
          protocol_definition?
        )
        |> Enum.flat_map(fn public_arity ->
          public_definition_entries(
            context,
            name,
            public_arity,
            definition,
            metadata,
            delegate_specs,
            MapSet.member?(protocol_callbacks, {name, public_arity})
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

  defp default_wrapper_identities(definitions) do
    definitions
    |> Enum.flat_map(fn
      {{name, arity}, definition, metadata, _clauses} when definition in [:def, :defmacro] ->
        case Keyword.get(metadata, :defaults, 0) do
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
         {_metadata, _args, [], {:super, metadata, _defaults}},
         definition,
         name
       ) do
    Keyword.get(metadata, :super) == {definition, name}
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
    type = if definition == :def, do: {:function, :public}, else: {:macro, :public}

    entry =
      Entry.definition(
        context.source_path,
        context.root_block,
        Subject.mfa(context.module, name, arity),
        type,
        definition_range(metadata, name),
        context.app
      )

    case Keyword.get(metadata, :context) do
      macro_context
      when is_atom(macro_context) and not is_nil(macro_context) and
             macro_context != context.module and not protocol_callback? ->
        Entry.put_metadata(entry, %{
          original_mfa: Subject.mfa(macro_context, name, arity),
          via: :use
        })

      _ ->
        entry
    end
  end

  defp remote_context_definition_entries(source_path, module, compiler_definitions) do
    context = %{
      app: ApplicationCache.application(module),
      module: module,
      root_block: Block.root(),
      source_path: source_path
    }

    compiler_definitions
    |> Enum.flat_map(&remote_context_definition_entry(&1, context))
    |> Enum.uniq_by(&{&1.subject, &1.type})
  end

  defp remote_context_definition_entry(
         {{name, arity}, definition, metadata},
         context
       )
       when is_atom(name) and is_integer(arity) and definition in [:def, :defmacro] and
              is_list(metadata) do
    with macro_context when is_atom(macro_context) and not is_nil(macro_context) <-
           Keyword.get(metadata, :context),
         true <- macro_context != context.module do
      type = if definition == :def, do: {:function, :public}, else: {:macro, :public}

      entry =
        Entry.definition(
          context.source_path,
          context.root_block,
          Subject.mfa(context.module, name, arity),
          type,
          definition_range(metadata, name),
          context.app
        )

      [
        Entry.put_metadata(entry, %{
          original_mfa: Subject.mfa(macro_context, name, arity),
          via: :use
        })
      ]
    else
      _ -> []
    end
  end

  defp remote_context_definition_entry(_definition, _context), do: []

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
    |> Map.get(:definitions, [])
    |> Enum.flat_map(&delegate_specs/1)
    |> Map.new()
  end

  defp delegate_specs({{name, arity}, :def, metadata, clauses}) do
    with true <- delegate_metadata?(metadata),
         {:ok, module, target_name, target_arity} <- delegate_target(clauses) do
      defaults = Keyword.get(metadata, :defaults, 0)

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
    Keyword.has_key?(metadata, :line) and not Keyword.has_key?(metadata, :column) and
      not Keyword.has_key?(metadata, :context)
  end

  defp delegate_target([{_metadata, args, [], body}]) do
    with {{:., _dot_metadata, [module, name]}, _call_metadata, call_args} <- body,
         true <- is_atom(module),
         true <- is_atom(name),
         true <- same_variables?(args, call_args) do
      {:ok, module, name, length(call_args)}
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

  defp variable_identity({name, metadata, context}) when is_atom(name) and is_list(metadata) do
    {name, Keyword.get(metadata, :version), context}
  end

  defp variable_identity(_ast), do: :error

  defp module_type(%{attributes: attributes}) do
    if Keyword.has_key?(attributes, :__protocol__), do: {:protocol, :definition}, else: :module
  end

  defp module_type(_), do: :module

  defp protocol_implementation(%{attributes: attributes}) do
    with impl when is_list(impl) <- Keyword.get(attributes, :__impl__),
         protocol when is_atom(protocol) <- Keyword.get(impl, :protocol) do
      {:ok, protocol}
    else
      _ -> :error
    end
  end

  defp protocol_implementation(_metadata), do: :error

  defp protocol_callbacks(metadata) do
    metadata
    |> Map.get(:definitions, [])
    |> Enum.find_value([], fn
      {{:__protocol__, 1}, :def, _definition_metadata, clauses} ->
        protocol_callback_clauses(clauses)

      _definition ->
        nil
    end)
    |> MapSet.new()
  end

  defp protocol_callback_clauses(clauses) do
    clauses
    |> Enum.find_value([], fn
      {_metadata, [:functions], [], functions} when is_list(functions) -> functions
      _clause -> nil
    end)
    |> Enum.flat_map(fn
      {name, arity} when is_atom(name) and is_integer(arity) -> [{name, arity}]
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

    if protocol_definition? and Keyword.has_key?(definition_metadata, :context) do
      Enum.filter(arities, &MapSet.member?(protocol_callbacks, {name, &1}))
    else
      arities
    end
  end

  defp definition_range(metadata, name) do
    line = Keyword.get(metadata, :line, 1)
    column = Keyword.get(metadata, :column, 1)

    range(line, column, name |> Atom.to_string() |> String.length())
  end

  # BEAM debug metadata stores nested modules under their expanded names, but the
  # source often only contains the visible suffix (`defmodule Child`). Scan the
  # definition line for the source spelling before falling back to compiler data.
  defp module_range(metadata, source_lines) do
    {line, fallback_column} = metadata_position(metadata)
    module_name = metadata |> Map.fetch!(:module) |> Forge.Formats.module()

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
      fn {:indexed, source_path, _metadata, _manifest_entry} -> source_path end,
      fn {:indexed, _source_path, metadata, _manifest_entry} ->
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
    case Map.get(metadata, :anno) || Map.get(metadata, :line) do
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

  defp task_result!({:ok, items}), do: items

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
