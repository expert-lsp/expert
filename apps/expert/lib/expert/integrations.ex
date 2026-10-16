defmodule Expert.Integrations do
  @moduledoc false

  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @callback index(Project.t(), binary(), map(), String.t()) :: [Entry.t()]

  @indexers [
    {Expert.Integrations.SemanticMetadata.Indexer, 2},
    {Expert.Integrations.Spark.Indexer, 2}
  ]

  @indexer_versions @indexers
                    |> Enum.map(fn {module, version} -> {Atom.to_string(module), version} end)
                    |> Enum.sort()

  def indexer_versions, do: @indexer_versions

  def index_beam(project, binary, metadata, source_path) do
    Enum.flat_map(@indexers, fn {indexer, _version} ->
      indexer.index(project, binary, metadata, source_path)
    end)
  end
end
