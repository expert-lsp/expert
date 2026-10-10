defmodule Expert.Integrations.SemanticMetadata.Indexer do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Forge.Search.Indexer.Entry

  @provider "semantic"

  @impl Expert.Integrations
  def index(_project, _binary, metadata, source_path) do
    owner = metadata |> Map.fetch!(:module) |> Atom.to_string()

    metadata
    |> Map.get(:attributes, [])
    |> Decoder.decode()
    |> Enum.with_index()
    |> Enum.map(fn {document, index} ->
      Entry.integration(source_path, @provider, :dsl, key(owner, index), document)
    end)
  end

  defp key(owner, index), do: "#{owner}/#{index}"
end
