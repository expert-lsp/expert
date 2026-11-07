defmodule Expert.Search.Indexer do
  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.Cache
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ManifestStore
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Paths
  alias Expert.Search.Indexer.Quoted
  alias Expert.Search.Indexer.Sources
  alias Expert.Search.Store
  alias Expert.Search.Subject
  alias Forge.Project

  @rows_per_write 4_000

  def create_index(%Project{} = project, opts \\ []) when is_list(opts) do
    with :ok <- ManifestStore.invalidate(project),
         {:ok, manifest} <- build_index(project, opts),
         :ok <- ManifestStore.commit(project, manifest) do
      Cache.clear(project)
    end
  end

  def update_index(%Project{} = project, opts \\ []) when is_list(opts) do
    with path_to_ids when is_map(path_to_ids) <- Store.path_to_ids(project),
         {:ok, manifest} <- update_index(project, path_to_ids, opts),
         :ok <- ManifestStore.commit(project, manifest) do
      Cache.clear(project)
    end
  end

  def record_integrations(%Project{} = project) do
    ManifestStore.record_integrations(project, Integrations.indexer_module_names())
  end

  def document(%Project{} = project, %Forge.Document{} = document, imported_calls) do
    imported_calls =
      Map.new(imported_calls, fn {module, calls} ->
        {module,
         Map.new(calls, fn {line, column, imported_module, name, arity} ->
           {{line, column}, {imported_module, name, arity}}
         end)}
      end)

    analysis = Forge.Ast.analyze(document)
    {:ok, entries} = Quoted.index_with_cleanup(analysis, project, imported_calls)
    {:ok, document.path, entries}
  end

  defp build_index(%Project{} = project, opts) do
    :ok = EngineApi.clear_application_cache(project)

    try do
      replace_index(project, opts)
    after
      EngineApi.clear_application_cache(project)
    end
  end

  defp update_index(%Project{} = project, path_to_ids, opts) do
    :ok = EngineApi.clear_application_cache(project)
    paths = paths_for_project(project, opts)
    opts = Keyword.put(opts, :paths, paths)

    try do
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} ->
          indexer_module_names = Integrations.indexer_module_names()

          integrations_changed? =
            ManifestStore.integrations_changed?(project, manifest, indexer_module_names)

          with :ok <- ManifestStore.invalidate(project) do
            if integrations_changed?,
              do: replace_index(project, opts),
              else: refresh_index(project, manifest, path_to_ids, opts)
          end

        :missing ->
          replace_index(project, opts)
      end
    after
      EngineApi.clear_application_cache(project)
    end
  end

  defp replace_index(%Project{} = project, opts) do
    :ok = ModuleRegistry.clear(project)
    paths = paths_for_project(project, opts)

    with {:ok, state} <- replace_store(paths, new_stream_state(), project),
         :ok <- replace_modules(project) do
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
    :ok = ModuleRegistry.prune(project, paths.beam_paths)

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

    with {:ok, state} <-
           refresh_store(source_paths, beam_items, paths_to_clear, new_stream_state(), project),
         :ok <- update_modules(project, plan) do
      manifest = Manifest.apply_update(manifest, plan, manifest_entries(state))

      {:ok, manifest}
    end
  end

  defp beam_items_and_siblings(plan, manifest, paths, project) do
    beam_items = beam_items(plan.beam_paths_to_index, paths.applications, project)

    manifest_entries =
      Enum.flat_map(beam_items, fn {_batch, entries} -> entries end)

    sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries)

    if sibling_paths == [] do
      {beam_items, manifest_entries, []}
    else
      sibling_items = beam_items(sibling_paths, paths.applications, project)

      sibling_manifest_entries =
        Enum.flat_map(sibling_items, fn {_batch, entries} -> entries end)

      {beam_items ++ sibling_items, manifest_entries ++ sibling_manifest_entries, sibling_paths}
    end
  end

  defp beam_items(beam_paths, applications, project) do
    beam_paths
    |> Beams.stream(project: project, applications: applications)
    |> Enum.to_list()
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
       do: {path, Subject.key(subject), subtype, kind}

  defp entry_identity(%{path: path, subject: subject, subtype: subtype, type: type}),
    do: {path, Subject.key(subject), subtype, type}

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

  defp index_stream(%Paths{} = paths, project) do
    index_stream(
      project,
      paths.source_paths,
      paths.beam_paths,
      paths.applications,
      paths.source_paths
    )
  end

  defp index_stream(
         project,
         source_paths,
         beam_paths,
         applications,
         current_source_paths
       ) do
    beam_items = beam_items(beam_paths, applications, project)

    beam_manifest_entries =
      Enum.flat_map(beam_items, fn {_batch, manifest_entries} -> manifest_entries end)

    source_paths =
      include_beam_sources(source_paths, current_source_paths, beam_manifest_entries)

    index_stream(source_paths, beam_items, project)
  end

  # The source workers are linked to the process that builds this stream, so it
  # has to be the store's callback, which consumes it.
  defp index_stream(source_paths, beam_items, project) do
    source_paths
    |> Sources.stream(source_indexer(project), &Store.encode_batch/1)
    |> tag_stream(:source)
    |> Stream.concat(tag_stream(beam_items, :beam))
  end

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

  defp tag_stream(stream, origin) do
    Stream.map(stream, fn {batch, manifest_entries} -> {origin, batch, manifest_entries} end)
  end

  defp new_stream_state do
    %{
      manifest_entries: [],
      source_keys: MapSet.new()
    }
  end

  defp replace_store(%Paths{} = paths, state, project) do
    replacement = fn write_batch ->
      paths
      |> index_stream(project)
      |> stream_into_store(state, write_batch)
    end

    case Store.replace(project, replacement) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp refresh_store(source_paths, beam_items, paths_to_clear, state, project) do
    update = fn write_batch, write_state ->
      source_paths
      |> index_stream(beam_items, project)
      |> stream_into_store(state, write_batch, write_state)
    end

    case Store.apply_index_update(project, update, paths_to_clear) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp replace_modules(project) do
    case ModuleRegistry.persist(project) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp update_modules(project, %Manifest.Plan{} = plan) do
    case ModuleRegistry.persist(project, plan.beam_paths_to_index, plan.input_paths_to_remove) do
      :ok -> :ok
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
    result =
      Enum.reduce_while(stream, {state, write_state, [], 0}, fn item, acc ->
        buffer_item(item, acc, write_batch)
      end)

    case result do
      {:error, _reason} = error ->
        error

      {state, write_state, [], 0} ->
        {:ok, state, write_state}

      {state, write_state, batches, _rows} ->
        with {:ok, write_state} <- write_batch.(Enum.reverse(batches), write_state) do
          {:ok, state, write_state}
        end
    end
  end

  defp buffer_item(item, {state, write_state, batches, rows}, write_batch) do
    {batch, state} = consume_item(item, state)
    batches = [batch | batches]
    rows = rows + batch.rows

    if rows < @rows_per_write do
      {:cont, {state, write_state, batches, rows}}
    else
      case write_batch.(Enum.reverse(batches), write_state) do
        {:ok, write_state} -> {:cont, {state, write_state, [], 0}}
        {:error, _reason} = error -> {:halt, error}
      end
    end
  end

  # Source definitions win over the same definitions read from BEAM files,
  # which are written after all source batches.
  defp consume_item({:source, batch, manifest_entries}, state) do
    source_keys =
      Enum.reduce(batch.definitions, state.source_keys, fn {entry, _row}, keys ->
        MapSet.put(keys, source_key(entry))
      end)

    source_keys = Enum.reduce(batch.structures, source_keys, &MapSet.put(&2, source_key(&1)))
    state = remember_manifest_entries(state, manifest_entries)

    {batch, %{state | source_keys: source_keys}}
  end

  # Encoding BEAM entries any earlier keeps their rows on the store's heap for
  # the whole source phase and slows every collection in it.
  defp consume_item({:beam, entries, manifest_entries}, state) do
    entries =
      Enum.reject(entries, fn entry ->
        entry.subtype != :reference and MapSet.member?(state.source_keys, source_key(entry))
      end)

    {Store.encode_batch(entries), remember_manifest_entries(state, manifest_entries)}
  end

  defp source_key(%{path: path, subtype: :block_structure}), do: {:block_structure, path}
  defp source_key(entry), do: {:entry, entry_identity(entry)}

  defp remember_manifest_entries(state, manifest_entries) do
    %{state | manifest_entries: Enum.reverse(manifest_entries, state.manifest_entries)}
  end

  defp manifest_entries(state), do: Enum.reverse(state.manifest_entries)
end
