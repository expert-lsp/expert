defmodule Expert.IntegrationsTest do
  use ExUnit.Case, async: true

  test "returns stable versions for enabled BEAM indexers" do
    assert Expert.Integrations.indexer_versions() == [
             {Atom.to_string(Expert.Integrations.SemanticMetadata.Indexer), 2},
             {Atom.to_string(Expert.Integrations.Spark.Indexer), 2}
           ]
  end
end
