defmodule Forge.Search.Indexer.EntryTest do
  use ExUnit.Case, async: true

  alias Forge.Search.Indexer.Entry

  test "builds integration entries under the prefix of their provider and kind" do
    entry = Entry.integration("/lib.ex", "semantic", :dsl, "My.DSL/0", %{})

    assert entry.subject == "$integration/semantic/dsl/My.DSL/0"
    assert String.starts_with?(entry.subject, Entry.integration_subject_prefix("semantic", :dsl))
    assert {entry.type, entry.subtype} == {:metadata, :integration}
  end
end
