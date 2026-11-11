defmodule Expert.Integrations do
  @moduledoc false

  alias Expert.Search.Indexer.BeamFile
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @callback index(Project.t(), binary(), BeamFile.exports(), map(), String.t()) :: [Entry.t()]

  @indexers [
    {Expert.Integrations.SemanticMetadata.Indexer, 2},
    {Expert.Integrations.Spark.Indexer, 2}
  ]

  @indexer_versions @indexers
                    |> Enum.map(fn {module, version} -> {Atom.to_string(module), version} end)
                    |> Enum.sort()

  def indexer_versions, do: @indexer_versions

  def documents, do: [Expert.Integrations.EEx.document()]

  def index_beam(project, binary, exports, metadata, source_path) do
    Enum.flat_map(@indexers, fn {indexer, _version} ->
      indexer.index(project, binary, exports, metadata, source_path)
    end)
  end
end
