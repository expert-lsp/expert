defmodule Expert.Integrations.SemanticMetadata.IndexerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Forge.Test.Fixtures

  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Test.SemanticMetadataCase
  alias Forge.Search.Indexer.Entry

  test "stores each document of a module in its own entry" do
    first = document(:first)
    second = document(:second)

    %{module: module, binary: binary, attributes: attributes} =
      SemanticMetadataCase.compile_metadata!([first, second])

    entries =
      Indexer.index(project(), binary, %{module: module, attributes: attributes}, "/lib.ex")

    prefix = Indexer.subject_prefix()

    assert [
             %Entry{type: :metadata, subtype: :integration, subject: first_subject} = first_entry,
             %Entry{subject: second_subject} = second_entry
           ] = Enum.filter(entries, &String.starts_with?(&1.subject, prefix))

    assert first_entry.metadata.payload == first
    assert second_entry.metadata.payload == second
    assert first_subject != second_subject
  end

  test "skips a module whose metadata it cannot index, and says which" do
    Logger.put_module_level(Indexer, :warning)
    on_exit(fn -> Logger.put_module_level(Indexer, Logger.level()) end)
    document = %{contexts: :invalid}
    attributes = [elixir_semantic_metadata: [{:elixir_semantic_metadata_v1, document}]]
    metadata = %{module: My.Broken, attributes: attributes}

    assert {[], log} = with_log(fn -> Indexer.index(project(), "", metadata, "/lib.ex") end)
    assert log =~ "Could not index the semantic metadata of My.Broken"
  end

  test "names a document in a lookup entry for each call, language, and sigil it selects" do
    document = %{
      contexts: [
        %{mfa: {My.Query, :from, 1}, argument: 0, scope: :sources},
        %{mfa: {My.Query, :from, 2}, argument: 1, scope: :sources},
        %{language_id: "eex", scope: :sources},
        %{sigil: "H", scope: :sources}
      ],
      scopes: %{sources: %{entries: []}}
    }

    [document_entry | lookups] = Indexer.entries("/lib.ex", "My.Query/0", document)

    assert document_entry.subject == Indexer.document_subject("My.Query/0")
    assert Enum.all?(lookups, &(&1.metadata.payload == "My.Query/0"))

    assert Enum.map(lookups, & &1.subject) == [
             Indexer.lookup_subject({:call, :from}),
             Indexer.lookup_subject({:language, "eex"}),
             Indexer.lookup_subject({:sigil, "H"})
           ]
  end

  defp document(scope) do
    %{
      contexts: [%{mfa: {My.DSL, :configure, 1}, block: :do, scope: scope}],
      scopes: %{scope => %{entries: []}}
    }
  end
end
