defmodule Engine.IntegrationsTest do
  use ExUnit.Case, async: true

  test "returns stable names for enabled BEAM indexers" do
    assert Engine.Integrations.indexer_module_names() == [
             Atom.to_string(Engine.Integrations.Spark.Indexer)
           ]
  end
end
