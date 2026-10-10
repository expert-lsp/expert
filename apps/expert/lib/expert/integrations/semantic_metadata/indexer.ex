defmodule Expert.Integrations.SemanticMetadata.Indexer do
  @behaviour Expert.Integrations

  alias Forge.Search.Indexer.Entry

  @provider "semantic"

  @impl Expert.Integrations
  def index(_project, _binary, metadata, source_path) do
    documents =
      for value <-
            Keyword.get_values(Map.get(metadata, :attributes, []), :elixir_semantic_metadata),
          {:elixir_semantic_metadata_v1, document} <- List.wrap(value),
          do: document

    for {document, index} <- Enum.with_index(documents) do
      entry(source_path, "#{metadata.module}/#{index}", document)
    end
  end

  def entry(source_path, key, document) do
    Entry.integration(source_path, @provider, :dsl, key, document)
  end

  def subject_prefix, do: Entry.integration_subject_prefix(@provider, :dsl)
end
