defmodule Expert.Search.Indexer.ManifestStore do
  @moduledoc """
  Persists the indexer's incremental input registry.
  """

  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.Manifest.Entry
  alias Forge.Project

  @file_name "index_manifest.etf"
  @integrations_file_name "integrations.etf"

  @doc false
  def load(%Project{} = project) do
    with {:ok, binary} <- File.read(manifest_path(project)),
         {:ok, %{entries: entries}} when is_list(entries) <- safe_binary_to_term(binary),
         {:ok, manifest} <- decode_entries(entries) do
      {:ok, manifest}
    else
      {:error, :enoent} ->
        :missing

      _ ->
        invalidate(project)
        :missing
    end
  end

  def commit(%Project{} = project, %Manifest{} = manifest) do
    path = manifest_path(project)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      write_file(path, encode(manifest))
    end
  end

  def integrations_changed?(%Project{} = project, indexer_module_names)
      when is_list(indexer_module_names) do
    case load(project) do
      {:ok, %Manifest{} = manifest} ->
        integrations_changed?(project, manifest, indexer_module_names)

      :missing ->
        true
    end
  end

  def integrations_changed?(%Project{} = project, %Manifest{}, indexer_module_names)
      when is_list(indexer_module_names) do
    with {:ok, binary} <- File.read(integrations_path(project)),
         {:ok, recorded_names} when is_list(recorded_names) <- safe_binary_to_term(binary) do
      recorded_names != indexer_module_names
    else
      _ -> true
    end
  end

  def record_integrations(%Project{} = project, indexer_module_names)
      when is_list(indexer_module_names) do
    path = integrations_path(project)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      write_file(path, :erlang.term_to_binary(indexer_module_names))
    end
  end

  def invalidate(%Project{} = project) do
    with :ok <- remove_file(manifest_path(project)) do
      remove_file(integrations_path(project))
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  defp write_file(path, binary) do
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, binary),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      error ->
        File.rm(tmp_path)
        error
    end
  end

  defp encode(%Manifest{} = manifest) do
    %{entries: encode_entries(manifest)}
    |> :erlang.term_to_binary()
  end

  defp encode_entries(%Manifest{} = manifest) do
    manifest
    |> Manifest.entries()
    |> Enum.map(&encode_entry/1)
  end

  defp encode_entry(%Entry{} = entry) do
    %{
      input_path: entry.input_path,
      output_path: entry.output_path,
      output_paths: entry.output_paths,
      kind: Atom.to_string(entry.kind),
      mtime: entry.mtime,
      size: entry.size,
      source_path: entry.source_path,
      source_mtime: entry.source_mtime,
      source_size: entry.source_size
    }
  end

  defp decode_entries(entries) when is_list(entries) do
    {:ok, Manifest.new(Enum.map(entries, &decode_entry/1))}
  rescue
    _ -> :error
  end

  defp decode_entry(%{input_path: input_path, kind: kind, mtime: mtime, size: size} = entry) do
    %Entry{
      input_path: input_path,
      output_path: Map.get(entry, :output_path),
      output_paths: Map.get(entry, :output_paths),
      kind: decode_kind(kind),
      mtime: mtime,
      size: size,
      source_path: Map.get(entry, :source_path),
      source_mtime: Map.get(entry, :source_mtime),
      source_size: Map.get(entry, :source_size)
    }
  end

  defp decode_kind("source"), do: :source
  defp decode_kind("beam"), do: :beam
  defp decode_kind(:source), do: :source
  defp decode_kind(:beam), do: :beam

  defp safe_binary_to_term(binary) do
    seed_legacy_atoms()

    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> :error
  end

  defp seed_legacy_atoms do
    atoms = [
      :backend,
      :beam,
      :entries,
      :input_path,
      :kind,
      :mtime,
      nil,
      :output_path,
      :output_paths,
      :schema_version,
      :size,
      :source,
      :source_mtime,
      :source_path,
      :source_size
    ]

    Enum.each(atoms, fn
      atom when is_atom(atom) -> atom
      _ -> :ok
    end)
  end

  defp manifest_path(%Project{} = project), do: Path.join(root_path(project), @file_name)

  defp integrations_path(%Project{} = project),
    do: Path.join(root_path(project), @integrations_file_name)

  defp root_path(%Project{} = project) do
    Project.workspace_path(project, ["indexes", "manifest"])
  end
end
