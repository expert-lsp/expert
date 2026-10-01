defmodule Expert.IntegrationsTest do
  use ExUnit.Case, async: true

  test "returns stable names for enabled BEAM indexers" do
    assert Expert.Integrations.indexer_module_names() == [
             Atom.to_string(Expert.Integrations.Spark.Indexer)
           ]
  end
end
