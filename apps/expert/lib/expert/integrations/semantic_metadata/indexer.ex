defmodule Expert.Integrations.SemanticMetadata.Indexer do
  @behaviour Expert.Integrations

  alias Forge.Search.Indexer.Entry

  require Logger

  @provider "semantic"

  @impl Expert.Integrations
  def index(_project, _binary, metadata, source_path) do
    documents =
      for value <-
            Keyword.get_values(Map.get(metadata, :attributes, []), :elixir_semantic_metadata),
          {:elixir_semantic_metadata_v1, document} <- List.wrap(value),
          do: document

    for {document, index} <- Enum.with_index(documents),
        entry <- entries(source_path, "#{metadata.module}/#{index}", document),
        do: entry
  rescue
    exception ->
      Logger.warning(
        "Could not index the semantic metadata of #{inspect(metadata.module)}\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      []
  end

  def entries(source_path, key, document) do
    lookups =
      for lookup <- document.contexts |> Enum.map(&lookup/1) |> Enum.uniq(),
          do: Entry.integration(source_path, @provider, :context, lookup_key(lookup), key)

    [Entry.integration(source_path, @provider, :dsl, key, document) | lookups]
  end

  def subject_prefix, do: Entry.integration_subject_prefix(@provider, :dsl)

  def document_subject(key), do: subject_prefix() <> key

  def lookup_subject(lookup),
    do: Entry.integration_subject_prefix(@provider, :context) <> lookup_key(lookup)

  defp lookup(%{mfa: {_module, name, _arity}}), do: {:call, name}
  defp lookup(%{language_id: language_id}), do: {:language, language_id}
  defp lookup(%{sigil: sigil}), do: {:sigil, sigil}

  defp lookup_key({kind, name}), do: "#{kind}/#{name}"
end
