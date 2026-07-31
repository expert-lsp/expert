defmodule Engine.Integrations do
  @moduledoc """
  Registers dependency BEAM indexers and contextual completion providers.
  """

  @callback index(binary(), map(), String.t()) :: [Forge.Search.Indexer.Entry.t()]

  @beam_indexers [Engine.Integrations.Spark.Indexer]
  @completion_providers [Engine.Integrations.Spark.Completion]

  def index_beam(binary, metadata, source_path) do
    Enum.flat_map(@beam_indexers, & &1.index(binary, metadata, source_path))
  end

  def complete(env) do
    Enum.find_value(@completion_providers, :ignore, fn provider ->
      case provider.complete(env) do
        :ignore -> nil
        result -> result
      end
    end)
  end
end
