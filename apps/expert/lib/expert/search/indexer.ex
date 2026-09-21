defmodule Expert.Search.Indexer do
  alias Expert.EngineApi
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ManifestStore
  alias Expert.Search.Indexer.Paths
  alias Expert.Search.Indexer.Sources
  alias Forge.ProcessCache
  alias Forge.Project

  require ProcessCache

  def create_index(%Project{} = project, opts \\ []) do
    with_indexer_context(project, fn ->
      {entries, manifest} = create_index_data(project, opts)

      {:ok, entries, manifest}
    end)
  end

  def commit_manifest(%Project{} = project, %Manifest{} = manifest) do
    ManifestStore.commit(project, manifest)
  end

  def update_index(%Project{} = project, path_to_ids, opts \\ []) when is_map(path_to_ids) do
    with_indexer_context(project, fn ->
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} -> refresh_index(project, manifest, path_to_ids, opts)
        :missing -> replace_index(project, path_to_ids, opts)
      end
    end)
  end

  def document(%Project{} = project, uri) do
    with {:ok, document, analysis} <- Forge.Document.Store.fetch(uri, :analysis),
         {:ok, entries} <-
           Expert.Search.Indexer.Quoted.index_with_cleanup(analysis, project) do
      {:ok, document.path, entries}
    end
  end

  defp create_index_data(%Project{} = project, opts) do
    paths = paths_for_project(project, opts)
    {entries, manifest_entries} = index_paths(project, paths)

    {entries, Manifest.new(manifest_entries)}
  end

  defp replace_index(%Project{} = project, path_to_ids, opts) do
    {entries, manifest} = create_index_data(project, opts)
    paths_to_clear = stored_paths_to_clear(path_to_ids, entries)

    {:ok, entries, paths_to_clear, manifest}
  end

  defp refresh_index(%Project{} = project, %Manifest{} = manifest, path_to_ids, opts) do
    {entries, paths_to_clear, manifest} = update_index_data(project, manifest, path_to_ids, opts)

    {:ok, entries, paths_to_clear, manifest}
  end

  defp update_index_data(%Project{} = project, %Manifest{} = manifest, path_to_ids, opts) do
    paths = paths_for_project(project, opts)

    plan =
      manifest
      |> Manifest.plan(paths)
      |> include_missing_stored_outputs(manifest, paths, path_to_ids)

    {entries, manifest_entries, plan} = index_plan(project, plan, manifest, paths)

    paths_to_clear = Manifest.output_paths_to_clear(manifest, plan, manifest_entries)
    manifest = Manifest.apply_update(manifest, plan, manifest_entries)

    {entries, paths_to_clear, manifest}
  end

  defp paths_for_project(%Project{} = project, opts) do
    %Paths{} = paths = Keyword.get_lazy(opts, :paths, fn -> Paths.for_project(project) end)

    if Keyword.get(opts, :beams?, true) do
      paths
    else
      %Paths{paths | beam_paths: []}
    end
  end

  defp index_plan(
         %Project{} = project,
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         %Paths{} = paths
       ) do
    {source_entries, source_manifest_entries} =
      Sources.index(plan.source_paths_to_index, source_indexer(project))

    {beam_entries, beam_manifest_entries, beam_paths_to_index} =
      index_beam_plan(plan, manifest, paths)

    plan = %Manifest.Plan{plan | beam_paths_to_index: beam_paths_to_index}

    {merge_entries(source_entries, beam_entries),
     source_manifest_entries ++ beam_manifest_entries, plan}
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
  defp index_beam_plan(%Manifest.Plan{beam_paths_to_index: []}, _manifest, _paths) do
    {[], [], []}
  end

  defp index_beam_plan(%Manifest.Plan{} = plan, %Manifest{} = manifest, %Paths{} = paths) do
    {entries, manifest_entries} =
      Beams.index(plan.beam_paths_to_index, applications: paths.applications)

    sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries)

    case sibling_paths do
      [] ->
        {entries, manifest_entries, plan.beam_paths_to_index}

      [_ | _] ->
        {sibling_entries, sibling_manifest_entries} =
          Beams.index(sibling_paths, applications: paths.applications)

        {entries ++ sibling_entries, manifest_entries ++ sibling_manifest_entries,
         Enum.uniq(plan.beam_paths_to_index ++ sibling_paths)}
    end
  end

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

  defp index_paths(%Project{} = project, %Paths{} = paths) do
    {source_entries, source_manifest_entries} =
      Sources.index(paths.source_paths, source_indexer(project))

    {beam_entries, beam_manifest_entries} =
      Beams.index(paths.beam_paths, applications: paths.applications)

    {merge_entries(source_entries, beam_entries),
     source_manifest_entries ++ beam_manifest_entries}
  end

  defp merge_entries(source_entries, beam_entries) do
    source_identities = MapSet.new(source_entries, &entry_identity/1)

    source_block_paths =
      source_entries |> Enum.filter(&(&1.subtype == :block_structure)) |> MapSet.new(& &1.path)

    beam_supplements =
      Enum.reject(beam_entries, fn entry ->
        MapSet.member?(source_identities, entry_identity(entry)) or
          (entry.subtype == :block_structure and MapSet.member?(source_block_paths, entry.path))
      end)

    source_entries ++ beam_supplements
  end

  defp entry_identity(%{path: path, subject: subject, subtype: subtype, type: {kind, _}})
       when kind in [:function, :macro],
       do: {path, subject, subtype, kind}

  defp entry_identity(%{path: path, subject: subject, subtype: subtype, type: type}),
    do: {path, subject, subtype, type}

  defp source_indexer(%Project{} = project) do
    fn path, source -> Expert.Search.Indexer.Source.index(path, source, nil, project) end
  end

  defp stored_paths_to_clear(path_to_ids, entries) do
    indexed_paths = MapSet.new(entries, & &1.path)

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

  defp with_indexer_context(%Project{} = project, fun) when is_function(fun, 0) do
    :ok = EngineApi.clear_application_cache(project)

    ProcessCache.with_cleanup do
      fun.()
    end
  after
    EngineApi.clear_application_cache(project)
  end
end
