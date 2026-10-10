defmodule Expert.Integrations.SemanticMetadata.Indexer do
  @behaviour Expert.Integrations

  alias Expert.Search.Indexer.BeamFile
  alias Forge.Search.Indexer.Entry

  @provider "semantic"
  @attribute "elixir_semantic_metadata"

  @impl Expert.Integrations
  def index(_project, beam, _exports, metadata, source_path) do
    for {document, index} <- Enum.with_index(documents(beam, metadata)) do
      entry(source_path, "#{Map.fetch!(metadata, "module")}/#{index}", document)
    end
  end

  def entry(source_path, key, document) do
    Entry.integration(source_path, @provider, :dsl, key, document)
  end

  def subject_prefix, do: Entry.integration_subject_prefix(@provider, :dsl)

  # Decoding the attributes creates an atom for every name in them, so only the
  # modules that publish semantic metadata are decoded.
  defp documents(beam, metadata) do
    with true <- List.keymember?(Map.get(metadata, "attributes", []), @attribute, 0),
         {:ok, chunk} <- BeamFile.chunk(beam, "Attr") do
      for {:elixir_semantic_metadata, values} <- :erlang.binary_to_term(chunk),
          {:elixir_semantic_metadata_v1, document} <- List.wrap(values),
          do: document
    else
      _ -> []
    end
  end
end
