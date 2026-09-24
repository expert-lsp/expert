defmodule Expert.Search.Indexer do
  alias Expert.EngineApi
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ManifestStore
  alias Expert.Search.Indexer.Paths
  alias Expert.Search.Indexer.Sources
  alias Expert.Search.Store
  alias Forge.Project

  require Logger

  @entry_chunk_size 4_000
  @cache_options [:set, :public, read_concurrency: true, write_concurrency: true]

  def create_index(%Project{} = project, opts \\ []) when is_list(opts) do
    with :ok <- ManifestStore.invalidate(project),
         :ok <- store_result(Store.replace(project, [])),
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
    :ok = EngineApi.clear_application_cache(project)
    cache = open_cache()

    try do
      paths = paths_for_project(project, opts)

      with {:ok, state} <-
             paths
             |> index_stream(project, cache)
             |> persist_stream(new_stream_state(), project, false) do
        {:ok, Manifest.new(manifest_entries(state))}
      end
    after
      close_cache(cache)
      EngineApi.clear_application_cache(project)
    end
  end

  defp update_index(%Project{} = project, path_to_ids, opts) do
    :ok = EngineApi.clear_application_cache(project)
    cache = open_cache()

    try do
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} ->
          with :ok <- ManifestStore.invalidate(project) do
            refresh_index(project, cache, manifest, path_to_ids, opts)
          end

        :missing ->
          replace_index(project, cache, path_to_ids, opts)
      end
    after
      close_cache(cache)
      EngineApi.clear_application_cache(project)
    end
  end

  defp replace_index(%Project{} = project, cache, path_to_ids, opts) do
    paths = paths_for_project(project, opts)

    with {:ok, state} <-
           paths
           |> index_stream(project, cache)
           |> persist_stream(new_stream_state(), project, true),
         paths_to_clear = stored_paths_to_clear(path_to_ids, state.cleared_paths),
         {:ok, state} <- clear_paths(state, paths_to_clear, project) do
      {:ok, Manifest.new(manifest_entries(state))}
    end
  end

  defp refresh_index(
         %Project{} = project,
         cache,
         %Manifest{} = manifest,
         path_to_ids,
         opts
       ) do
    paths = paths_for_project(project, opts)

    plan =
      manifest
      |> Manifest.plan(paths)
      |> include_missing_stored_outputs(manifest, paths, path_to_ids)

    initial_stream =
      index_stream(
        project,
        cache,
        plan.source_paths_to_index,
        plan.beam_paths_to_index,
        paths.applications
      )

    with {:ok, state} <- persist_stream(initial_stream, new_stream_state(), project, true),
         sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries(state)),
         {:ok, state} <-
           sibling_paths
           |> beam_stream(paths.applications)
           |> persist_stream(state, project, true),
         plan = %Manifest.Plan{
           plan
           | beam_paths_to_index: Enum.uniq(plan.beam_paths_to_index ++ sibling_paths)
         },
         manifest_entries = manifest_entries(state),
         paths_to_clear = Manifest.output_paths_to_clear(manifest, plan, manifest_entries),
         {:ok, _state} <- clear_paths(state, paths_to_clear, project) do
      manifest = Manifest.apply_update(manifest, plan, manifest_entries)

      {:ok, manifest}
    end
  end

  defp paths_for_project(%Project{} = project, opts) do
    %Paths{} = paths = Keyword.get_lazy(opts, :paths, fn -> Paths.for_project(project) end)

    if Keyword.get(opts, :beams?, true) do
      paths
    else
      %Paths{paths | beam_paths: []}
    end
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

  defp include_missing_stored_outputs(
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

  defp source_indexer(%Project{} = project, cache) do
    fn path, source -> Expert.Search.Indexer.Source.index(path, source, nil, project, cache) end
  end

  defp stored_paths_to_clear(path_to_ids, indexed_paths) do
    path_to_ids
    |> stored_paths()
    |> MapSet.difference(indexed_paths)
    |> Enum.to_list()
  end

  defp stored_paths(path_to_ids) when is_map(path_to_ids) do
    path_to_ids
    |> Map.keys()
    |> MapSet.new()
  end

  defp index_stream(%Paths{} = paths, %Project{} = project, cache) do
    index_stream(project, cache, paths.source_paths, paths.beam_paths, paths.applications)
  end

  defp index_stream(%Project{} = project, cache, source_paths, beam_paths, applications) do
    source_paths
    |> Sources.stream(source_indexer(project, cache))
    |> tag_stream(:source)
    |> Stream.concat(beam_stream(beam_paths, applications))
  end

  defp beam_stream(paths, applications) do
    paths
    |> Beams.stream(applications: applications)
    |> tag_stream(:beam)
  end

  defp tag_stream(stream, origin) do
    Stream.map(stream, fn {entry, manifest_entries} -> {origin, entry, manifest_entries} end)
  end

  defp new_stream_state do
    %{
      manifest_entries: [],
      source_keys: MapSet.new(),
      cleared_paths: MapSet.new()
    }
  end

  defp persist_stream(stream, state, project, replace_paths?) do
    stream
    |> Stream.chunk_every(@entry_chunk_size)
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, state} ->
      {entries, state} = consume_chunk(chunk, state)

      paths_to_clear =
        if replace_paths? do
          entries
          |> MapSet.new(& &1.path)
          |> MapSet.difference(state.cleared_paths)
          |> MapSet.to_list()
        else
          []
        end

      case persist_chunk(project, entries, paths_to_clear) do
        :ok ->
          state = %{
            state
            | cleared_paths: MapSet.union(state.cleared_paths, MapSet.new(paths_to_clear))
          }

          {:cont, {:ok, state}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp consume_chunk(chunk, state) do
    {entries, state} =
      Enum.reduce(chunk, {[], state}, fn {origin, entry, manifest_entries}, {entries, state} ->
        state = remember_manifest_entries(state, manifest_entries)
        consume_entry(origin, entry, entries, state)
      end)

    {Enum.reverse(entries), state}
  end

  defp consume_entry(_origin, nil, entries, state), do: {entries, state}

  defp consume_entry(:source, entry, entries, state) do
    state = %{state | source_keys: MapSet.put(state.source_keys, source_key(entry))}

    {[entry | entries], state}
  end

  defp consume_entry(:beam, entry, entries, state) do
    if MapSet.member?(state.source_keys, source_key(entry)) do
      {entries, state}
    else
      {[entry | entries], state}
    end
  end

  defp source_key(%{path: path, subtype: :block_structure}), do: {:block_structure, path}
  defp source_key(entry), do: {:entry, entry_identity(entry)}

  defp remember_manifest_entries(state, manifest_entries) do
    %{state | manifest_entries: Enum.reverse(manifest_entries, state.manifest_entries)}
  end

  defp clear_paths(state, paths, project) do
    paths =
      paths
      |> MapSet.new()
      |> MapSet.difference(state.cleared_paths)
      |> MapSet.to_list()

    case persist_chunk(project, [], paths) do
      :ok -> {:ok, %{state | cleared_paths: MapSet.union(state.cleared_paths, MapSet.new(paths))}}
      {:error, _} = error -> error
    end
  end

  defp persist_chunk(_project, [], []), do: :ok

  defp persist_chunk(project, entries, paths) do
    with :ok <- clear_store_paths(project, paths) do
      insert_entries(project, entries)
    end
  end

  defp clear_store_paths(_project, []), do: :ok

  defp clear_store_paths(project, paths) do
    store_result(Store.apply_index_update(project, [], paths))
  end

  defp insert_entries(_project, []), do: :ok
  defp insert_entries(project, entries), do: store_result(Store.insert(project, entries))

  defp store_result(:ok), do: :ok
  defp store_result({:error, reason}), do: {:error, {:store, reason}}

  defp manifest_entries(state), do: Enum.reverse(state.manifest_entries)

  defp open_cache do
    :ets.new(__MODULE__, @cache_options)
  end

  defp close_cache(cache) do
    entries = :ets.info(cache, :size)
    bytes = :ets.info(cache, :memory) * :erlang.system_info(:wordsize)

    Logger.info("Index cache used #{entries} entries and #{bytes} bytes")
    :ets.delete(cache)
  end
end
