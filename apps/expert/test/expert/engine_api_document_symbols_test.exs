defmodule Expert.EngineApi.DocumentSymbolsTest do
  use ExUnit.Case, async: true

  import Forge.Test.Fixtures

  alias Expert.EngineApi

  @moduletag :capture_log

  describe "document_symbols/2" do
    test "returns an empty list instead of raising when the document could not be resolved" do
      # Handlers that cannot resolve the request's document (for example, a
      # documentSymbol request for a file that is not in the document store)
      # fall back to nil. The API must treat that as "no symbols" rather than
      # raising a FunctionClauseError on the %Document{} pattern match.
      assert EngineApi.document_symbols(project(), nil) == []
    end
  end
end
