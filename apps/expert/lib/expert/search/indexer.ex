defmodule Expert.Search.Indexer do
  alias Expert.EngineApi
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ManifestStore
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Paths
  alias Expert.Search.Indexer.Sources
  alias Expert.Search.Store
  alias Expert.Search.Subject
  alias Forge.Project

  @entry_chunk_size 4_000

  def create_index(%Project{} = project, opts \\ []) when is_list(opts) do
    with :ok <- ManifestStore.invalidate(project),
         {:ok, manifest} <- build_index(project, opts) do
      ManifestStore.commit(project, manifest)
    end
  end

  def update_index(%Project{} = project, opts \\ []) when is_list(opts) do
    with path_to_ids when is_map(path_to_ids) <- Store.path_to_ids(project),
         {:ok, manifest} <- update_index(project, path_to_ids, opts) do
      ManifestStore.commit(project, manifest)
    end
  end

  def document(%Project{} = project, uri) do
    with {:ok, document, analysis} <- Forge.Document.Store.fetch(uri, :analysis),
         {:ok, entries} <-
           Expert.Search.Indexer.Quoted.index_with_cleanup(analysis, project) do
      {:ok, document.path, entries}
    end
  end

  defp build_index(%Project{} = project, opts) do
    :ok = ModuleRegistry.clear(project)

    try do
      paths = Keyword.get_lazy(opts, :paths, fn -> Paths.without_sources(project) end)

      with {:ok, state} <- replace_store(paths, new_stream_state(), project, true) do
        {:ok, Manifest.new(manifest_entries(state))}
      end
    after
      EngineApi.clear_application_cache_async(project)
    end
  end

  defp update_index(%Project{} = project, path_to_ids, opts) do
    :ok = EngineApi.clear_application_cache(project)
    paths = paths_for_project(project, opts)
    :ok = ModuleRegistry.prune(project, paths.beam_paths)
    opts = Keyword.put(opts, :paths, paths)

    try do
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} ->
          with :ok <- ManifestStore.invalidate(project) do
            refresh_index(project, manifest, path_to_ids, opts)
          end

        :missing ->
          replace_index(project, path_to_ids, opts)
      end
    after
      EngineApi.clear_application_cache(project)
    end
  end

  defp replace_index(%Project{} = project, _path_to_ids, opts) do
    paths = paths_for_project(project, opts)

    with {:ok, state} <- replace_store(paths, new_stream_state(), project, false) do
      {:ok, Manifest.new(manifest_entries(state))}
    end
  end

  defp refresh_index(
         %Project{} = project,
         %Manifest{} = manifest,
         path_to_ids,
         opts
       ) do
    paths = paths_for_project(project, opts)

    plan =
      manifest
      |> Manifest.plan(paths)
      |> reindex_missing_outputs(manifest, paths, path_to_ids)

    {beam_items, beam_manifest_entries, sibling_paths} =
      beam_items_and_siblings(plan, manifest, paths, project)

    plan = %Manifest.Plan{
      plan
      | beam_paths_to_index: Enum.uniq(plan.beam_paths_to_index ++ sibling_paths)
    }

    paths_to_clear =
      manifest
      |> Manifest.output_paths_for_inputs(plan.beam_paths_to_index)
      |> MapSet.union(MapSet.new(plan.source_paths_to_index))
      |> MapSet.union(MapSet.new(plan.output_paths_to_clear))
      |> MapSet.union(
        MapSet.new(
          for %Manifest.Entry{output_path: path} <- beam_manifest_entries,
              is_binary(path),
              do: path
        )
      )
      |> MapSet.to_list()

    source_paths =
      include_beam_sources(
        plan.source_paths_to_index,
        paths.source_paths,
        beam_manifest_entries
      )

    stream =
      source_paths
      |> Sources.stream(source_indexer(project), &encode_file/1)
      |> tag_stream(:source)
      |> Stream.concat(tag_stream(beam_items, :beam))

    with {:ok, state} <- refresh_store(stream, paths_to_clear, new_stream_state(), project) do
      manifest = Manifest.apply_update(manifest, plan, manifest_entries(state))

      {:ok, manifest}
    end
  end

  defp beam_items_and_siblings(plan, manifest, paths, project) do
    beam_items =
      plan.beam_paths_to_index
      |> Beams.stream(project: project, applications: paths.applications)
      |> Enum.to_list()

    manifest_entries =
      Enum.flat_map(beam_items, fn {_entry, entries} -> entries end)

    sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries)

    if sibling_paths == [] do
      {beam_items, manifest_entries, []}
    else
      sibling_items =
        sibling_paths
        |> Beams.stream(project: project, applications: paths.applications)
        |> Enum.to_list()

      sibling_manifest_entries =
        Enum.flat_map(sibling_items, fn {_entry, entries} -> entries end)

      {beam_items ++ sibling_items, manifest_entries ++ sibling_manifest_entries, sibling_paths}
    end
  end

  defp paths_for_project(%Project{} = project, opts) do
    %Paths{} = paths = Keyword.get_lazy(opts, :paths, fn -> Paths.for_project(project) end)
    paths
  end

  # Search entries use the source file path as their `path`. They do not carry the
  # BEAM file path because entries model searchable source symbols. The BEAM input
  # path is incremental-indexing state, tracked by the manifest.
  #
  # A single source file can produce multiple BEAM files. For example:
  #
  #   defmodule Parent do
  #     defmodule Child do
  #     end
  #   end
  #
  # produces both `Elixir.Parent.beam` and `Elixir.Parent.Child.beam`. Entries from
  # both BEAM files are stored under the same source path.
  #
  # Updating the index for a source path is a full replacement: delete all existing
  # entries for that source path, then insert the entries from this indexing pass.
  # If we index only a newly discovered child BEAM, the replacement set contains
  # only child entries, so existing parent entries for the same source path would be
  # deleted.
  #
  # Supporting narrower replacement would require storing BEAM-origin paths in
  # the search store which would potentially increase the index size by a lot
  # in large codebases. As a compromise, this keeps the existing source-path
  # replacement model and only reindexes known BEAMs that share a source path
  # with the new BEAM.
  defp beam_sibling_paths(
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         %Paths{} = paths,
         manifest_entries
       ) do
    new_beam_paths =
      plan.beam_paths_to_index
      |> Enum.filter(&(Manifest.fetch(manifest, &1) == :error))
      |> MapSet.new()

    output_paths =
      for %Manifest.Entry{kind: :beam, input_path: input_path, output_path: output_path} <-
            manifest_entries,
          is_binary(output_path),
          MapSet.member?(new_beam_paths, input_path),
          into: MapSet.new() do
        output_path
      end

    current_beam_paths = MapSet.new(paths.beam_paths)
    planned_beam_paths = MapSet.new(plan.beam_paths_to_index)

    for %Manifest.Entry{kind: :beam, input_path: input_path, output_path: output_path} <-
          Manifest.entries(manifest),
        is_binary(output_path),
        MapSet.member?(output_paths, output_path),
        MapSet.member?(current_beam_paths, input_path),
        not MapSet.member?(planned_beam_paths, input_path) do
      input_path
    end
  end

  defp reindex_missing_outputs(
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         paths,
         path_to_ids
       ) do
    stored_paths = stored_paths(path_to_ids)
    source_paths = MapSet.new(paths.source_paths)
    beam_paths = MapSet.new(paths.beam_paths)

    {missing_source_paths, missing_beam_paths} =
      manifest
      |> Manifest.entries()
      |> Enum.reduce({[], []}, fn
        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :source},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if MapSet.member?(source_paths, input_path) and
               not MapSet.member?(stored_paths, output_path) do
            {[input_path | source_acc], beam_acc}
          else
            {source_acc, beam_acc}
          end

        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :beam},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if MapSet.member?(beam_paths, input_path) and
               not MapSet.member?(stored_paths, output_path) do
            {source_acc, [input_path | beam_acc]}
          else
            {source_acc, beam_acc}
          end

        _entry, acc ->
          acc
      end)

    %Manifest.Plan{
      plan
      | source_paths_to_index: Enum.uniq(plan.source_paths_to_index ++ missing_source_paths),
        beam_paths_to_index: Enum.uniq(plan.beam_paths_to_index ++ missing_beam_paths)
    }
  end

  defp entry_identity(%{path: path, subject: subject, subtype: subtype, type: {kind, _}})
       when kind in [:function, :macro],
       do: {path, subject, subtype, kind}

  defp entry_identity(%{path: path, subject: subject, subtype: subtype, type: type}),
    do: {path, subject, subtype, type}

  defp source_indexer(project) do
    fn path, source ->
      Expert.Search.Indexer.Source.index(path, source, nil, project)
    end
  end

  defp stored_paths(path_to_ids) when is_map(path_to_ids) do
    path_to_ids
    |> Map.keys()
    |> MapSet.new()
  end

  # A full build registers every beam's module first, since indexing sources
  # looks modules up in the registry, then indexes the source files, and then
  # indexes only the beams their sources don't cover (see covered_beam?/4):
  # registering a beam costs far less than indexing it, and most are
  # covered. Registering doesn't need the sources listed or the engine's
  # application cache cleared, and indexing sources needs both, so they're
  # done while beams are registered.
  #
  # Returns the source stream, and a function making the beam stream from
  # the keys of the definitions the sources produced.
  defp index_streams(%Paths{} = paths, project, clear_cache?) do
    cache_cleared =
      Task.async(fn ->
        if clear_cache?, do: EngineApi.clear_application_cache(project), else: :ok
      end)

    sources_listed = Task.async(fn -> Paths.list_sources(paths) end)
    beam_opts = [project: project, applications: paths.applications]
    registered = Beams.register(paths.beam_paths, beam_opts)

    %Paths{source_paths: source_paths, source_stats: stats} =
      Task.await(sources_listed, :infinity)

    :ok = Task.await(cache_cleared, :infinity)

    sources =
      source_paths
      |> Sources.stream(source_indexer(project), &encode_file/1, stats)
      |> tag_stream(:source)

    beams = fn source_keys ->
      {covered, uncovered} =
        Enum.split_with(registered, &covered_beam?(&1, project, source_keys, stats))

      uncovered = for {beam_path, beam_stat, _source} <- uncovered, do: {beam_path, beam_stat}

      covered
      |> covered_manifest_items(stats)
      |> Stream.concat(Beams.stream(uncovered, beam_opts))
      |> tag_stream(:beam)
    end

    {sources, beams}
  end

  # A covered beam isn't indexed, but gets the manifest entry indexing it
  # would have made.
  defp covered_manifest_items(covered, source_stats) do
    for {beam_path, beam_stat, {_module, source_file}} <- covered do
      source_stat = Map.fetch!(source_stats, source_file)
      {:ok, entry} = Manifest.Entry.beam(beam_path, source_file, beam_stat, {:ok, source_stat})
      {nil, [entry]}
    end
  end

  # Indexing a beam makes its module's definition and those of its exports
  # (see Beams), so when its source file defines them all, the beam adds
  # nothing. Only beams compiled from one of the project's source files are
  # checked, since the manifest entry needs that file's stat.
  defp covered_beam?({_path, _stat, {module, source_file}}, project, source_keys, source_stats)
       when is_binary(source_file) do
    defined? = fn subject, kind ->
      MapSet.member?(source_keys, {:entry, {source_file, subject, :definition, kind}})
    end

    with %{^source_file => %File.Stat{}} <- source_stats,
         true <- defined?.(module, :module),
         {:ok, %{functions: functions, macros: macros}} <-
           ModuleRegistry.module_exports(project, module) do
      Enum.all?(functions, fn {name, arity} ->
        defined?.(Subject.mfa(module, name, arity), :function)
      end) and
        Enum.all?(macros, fn {name, arity} ->
          defined?.(Subject.mfa(module, name, arity), :macro)
        end)
    else
      _ -> false
    end
  end

  defp covered_beam?(_beam, _project, _source_keys, _source_stats), do: false

  defp include_beam_sources(source_paths, current_source_paths, manifest_entries) do
    # A BEAM batch replaces all entries for its source path. Parse that source in the same batch.
    current_source_paths = MapSet.new(current_source_paths)

    beam_source_paths =
      for %Manifest.Entry{kind: :beam, output_path: output_path} <- manifest_entries,
          MapSet.member?(current_source_paths, output_path) do
        output_path
      end

    Enum.uniq(source_paths ++ beam_source_paths)
  end

  # Encodes a file's entries in the indexing worker, with the keys beam
  # entries are checked against, so the file reaches the store as one item.
  defp encode_file(entries) do
    keys =
      for %{subtype: subtype} = entry <- entries,
          subtype in [:definition, :block_structure],
          do: {source_key(entry)}

    encoded = Store.encode_entries(entries)
    {:file, encoded, keys, length(encoded)}
  end

  defp tag_stream(stream, origin) do
    Stream.map(stream, fn {entry, manifest_entries} -> {origin, entry, manifest_entries} end)
  end

  defp new_stream_state do
    %{
      manifest_entries: [],
      source_keys: MapSet.new()
    }
  end

  defp replace_store(%Paths{} = paths, state, project, clear_cache?) do
    replacement = fn write_batch ->
      {sources, beams} = index_streams(paths, project, clear_cache?)

      with {:ok, state} <- stream_into_store(sources, state, write_batch) do
        state.source_keys |> beams.() |> stream_into_store(state, write_batch)
      end
    end

    case Store.replace(project, replacement) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp refresh_store(stream, paths_to_clear, state, project) do
    update = fn write_batch, write_state ->
      stream_into_store(stream, state, write_batch, write_state)
    end

    case Store.apply_index_update(project, update, paths_to_clear) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp stream_into_store(stream, state, write_batch) do
    write_batch_with_state = fn entries, write_state ->
      with :ok <- write_batch.(entries) do
        {:ok, write_state}
      end
    end

    case stream_into_store(stream, state, write_batch_with_state, nil) do
      {:ok, state, nil} -> {:ok, state}
      error -> error
    end
  end

  defp stream_into_store(stream, state, write_batch, write_state) do
    seen = open_seen(state)

    result =
      stream
      |> chunk_by_entries()
      |> Enum.reduce_while({nil, write_state}, fn chunk, {writing, write_state} ->
        entries = consume_chunk(chunk, seen)

        case await_write(writing, write_state) do
          {:ok, write_state} ->
            {:cont, {Task.async(fn -> write_batch.(entries, write_state) end), write_state}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)

    result =
      case result do
        {:error, _reason} = error -> error
        {writing, write_state} -> await_write(writing, write_state)
      end

    case result do
      {:ok, write_state} ->
        {:ok, close_seen(seen, state), write_state}

      {:error, _reason} = error ->
        close_seen(seen, state)
        error
    end
  end

  # Each batch is written in a task of its own, so the next batch is read from
  # the workers while it's written. Writes never overlap: the next starts once
  # the previous one is awaited, with the state it returned.
  defp await_write(nil, write_state), do: {:ok, write_state}
  defp await_write(%Task{} = writing, _write_state), do: Task.await(writing, :infinity)

  # The keys of the definitions seen so far and the manifest entries, in
  # order, grow with the project. In ETS they stay out of this process's heap,
  # which every garbage collection would otherwise copy.
  defp open_seen(state) do
    seen = %{
      source_keys: :ets.new(__MODULE__, [:set, :private]),
      manifest_entries: :ets.new(__MODULE__, [:ordered_set, :private])
    }

    :ets.insert(seen.source_keys, Enum.map(state.source_keys, fn key -> {key} end))
    remember_manifest_entries(seen, manifest_entries(state))
    seen
  end

  defp close_seen(seen, state) do
    manifest_entries =
      seen.manifest_entries
      |> :ets.tab2list()
      |> Enum.map(fn {_order, manifest_entry} -> manifest_entry end)

    source_keys = seen.source_keys |> :ets.tab2list() |> MapSet.new(fn {key} -> key end)
    :ets.delete(seen.source_keys)
    :ets.delete(seen.manifest_entries)
    %{state | manifest_entries: Enum.reverse(manifest_entries), source_keys: source_keys}
  end

  # Batches hold about @entry_chunk_size entries, however many files that is.
  defp chunk_by_entries(stream) do
    Stream.chunk_while(
      stream,
      {[], 0},
      fn item, {items, count} ->
        size = item_size(item)

        # A file that would overflow the batch starts the next one, so only a
        # file larger than a batch makes one larger.
        cond do
          items != [] and count + size > @entry_chunk_size ->
            {:cont, Enum.reverse(items), {[item], size}}

          count + size >= @entry_chunk_size ->
            {:cont, Enum.reverse([item | items]), {[], 0}}

          true ->
            {:cont, {[item | items], count + size}}
        end
      end,
      fn
        {[], _count} -> {:cont, {[], 0}}
        {items, _count} -> {:cont, Enum.reverse(items), {[], 0}}
      end
    )
  end

  defp item_size({_origin, {:file, _encoded, _keys, count}, _manifest_entries}), do: max(count, 1)
  defp item_size(_item), do: 1

  defp consume_chunk(chunk, seen) do
    chunk
    |> Enum.reduce([], fn {origin, item, manifest_entries}, entries ->
      remember_manifest_entries(seen, manifest_entries)
      consume_item(origin, item, entries, seen)
    end)
    |> Enum.reverse()
  end

  defp consume_item(_origin, nil, entries, _seen), do: entries

  defp consume_item(:source, {:file, encoded, keys, _count}, entries, seen) do
    :ets.insert(seen.source_keys, keys)
    Enum.reverse(encoded, entries)
  end

  defp consume_item(:beam, entry, entries, seen) do
    if :ets.member(seen.source_keys, source_key(entry)), do: entries, else: [entry | entries]
  end

  defp source_key(%{path: path, subtype: :block_structure}), do: {:block_structure, path}
  defp source_key(entry), do: {:entry, entry_identity(entry)}

  defp remember_manifest_entries(seen, manifest_entries) do
    for manifest_entry <- manifest_entries do
      :ets.insert(seen.manifest_entries, {System.unique_integer([:monotonic]), manifest_entry})
    end

    :ok
  end

  defp manifest_entries(state), do: Enum.reverse(state.manifest_entries)
end
