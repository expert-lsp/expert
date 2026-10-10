defmodule Expert.Integrations.SemanticMetadata.Indexer do
  @behaviour Expert.Integrations

  alias Expert.Search.Indexer.BeamFile
  alias Forge.Search.Indexer.Entry

  require Logger

  @provider "semantic"
  @attribute "elixir_semantic_metadata"

  @impl Expert.Integrations
  def index(_project, beam, _exports, metadata, source_path) do
    module = Map.fetch!(metadata, "module")

    for {document, index} <- Enum.with_index(documents(beam, metadata)),
        entry <- entries(source_path, "#{module}/#{index}", document),
        do: entry
  rescue
    exception ->
      Logger.warning(
        "Could not index the semantic metadata of #{metadata["module"]}\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      []
  end

  def entries(source_path, key, document) do
    lookups =
      for lookup <- lookups(document),
          do: Entry.integration(source_path, @provider, :context, lookup_key(lookup), key)

    [Entry.integration(source_path, @provider, :dsl, key, document) | lookups]
  end

  def subject_prefix, do: Entry.integration_subject_prefix(@provider, :dsl)

  def document_subject(key), do: subject_prefix() <> key

  def lookup_subject(lookup),
    do: Entry.integration_subject_prefix(@provider, :context) <> lookup_key(lookup)

  def lookups(document), do: document.contexts |> Enum.map(&lookup/1) |> Enum.uniq()

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

  defp lookup(%{mfa: {_module, name, _arity}}), do: {:call, name}
  defp lookup(%{language_id: language_id}), do: {:language, language_id}
  defp lookup(%{sigil: sigil}), do: {:sigil, sigil}

  defp lookup_key({kind, name}), do: "#{kind}/#{name}"
end
