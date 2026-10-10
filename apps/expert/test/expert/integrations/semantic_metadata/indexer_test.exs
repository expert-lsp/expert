defmodule Expert.Integrations.SemanticMetadata.IndexerTest do
  use ExUnit.Case, async: true

  import Forge.Test.Fixtures

  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Test.SemanticMetadataCase
  alias Forge.Search.Indexer.Entry

  test "stores each document of a module in its own entry" do
    first = document(:first)
    second = document(:second)

    %{module: module, binary: binary, attributes: attributes} =
      SemanticMetadataCase.compile_metadata!([first, second])

    prefix = Indexer.subject_prefix()

    assert [
             %Entry{type: :metadata, subtype: :integration, subject: first_subject} = first_entry,
             %Entry{subject: second_subject} = second_entry
           ] =
             Indexer.index(
               project(),
               binary,
               %{module: module, attributes: attributes},
               "/lib.ex"
             )

    assert first_entry.metadata.payload == first
    assert second_entry.metadata.payload == second
    assert String.starts_with?(first_subject, prefix)
    assert String.starts_with?(second_subject, prefix)
    assert first_subject != second_subject
  end

  defp document(scope) do
    %{
      contexts: [%{mfa: {My.DSL, :configure, 1}, block: :do, scope: scope}],
      scopes: %{scope => %{entries: []}}
    }
  end
end
