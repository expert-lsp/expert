defmodule Forge.Search.Indexer.EntryTest do
  use ExUnit.Case, async: true

  alias Forge.Search.Indexer.Entry

  test "builds integration subjects and prefixes" do
    assert Entry.integration_subject("spark", :extension, My.Extension) ==
             "$integration/spark/extension/Elixir.My.Extension"

    assert Entry.integration_subject_prefix("spark", :extension) ==
             "$integration/spark/extension/"

    assert Entry.integration_subject_prefix("spark", :behaviour, My.Behaviour) ==
             "$integration/spark/behaviour/Elixir.My.Behaviour/"
  end
end
