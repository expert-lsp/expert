defmodule Expert.Provider.Handlers.CodeActionResolveTest do
  use ExUnit.Case, async: true

  alias Expert.Document.Context
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias GenLSP.Enumerations.ErrorCodes
  alias GenLSP.Enumerations.LSPErrorCodes
  alias GenLSP.Requests.CodeActionResolve
  alias GenLSP.Structures

  @uri "file:///resolve_test.ex"
  @text "arg1\n|> foo()\n"
  @module Expert.Refactor.Pipeline.IntroducePipe

  defp context(version) do
    document = Document.new(@uri, @text, version)
    Context.new(@uri, document, Project.new("file:///project"))
  end

  defp resolve_request(action) do
    %CodeActionResolve{id: 1, params: action}
  end

  # The valid base payload is built through the real encoder so it can't drift
  # from the schema; malformed cases override individual keys with raw values.
  defp deferred_action(data_overrides) do
    range = Range.new(%Position{line: 1, character: 1}, %Position{line: 1, character: 1})
    base = Forge.CodeAction.to_refactor_data(@uri, 1, range, @module)
    data = Map.merge(base, data_overrides)

    %Structures.CodeAction{title: "Introduce pipe", kind: "refactor.rewrite", data: data}
  end

  defp handle(action, context) do
    Handlers.CodeActionResolve.handle(resolve_request(action), context)
  end

  describe "stale documents" do
    test "rejects with ContentModified when the document version has moved on" do
      action = deferred_action(%{"version" => 1})

      assert {:ok, %GenLSP.ErrorResponse{code: code, message: message}} =
               handle(action, context(2))

      assert code == LSPErrorCodes.content_modified()
      assert message =~ "changed"
    end
  end

  describe "malformed payloads" do
    test "rejects a non-integer range with InvalidParams" do
      action = deferred_action(%{"version" => 1, "range" => %{"start" => "wat"}})

      assert {:ok, %GenLSP.ErrorResponse{code: code}} = handle(action, context(1))
      assert code == ErrorCodes.invalid_params()
    end

    test "rejects an out-of-bounds line with InvalidParams" do
      action =
        deferred_action(%{
          "version" => 1,
          "range" => %{
            "start" => %{"line" => 9999, "character" => 1},
            "end" => %{"line" => 9999, "character" => 1}
          }
        })

      assert {:ok, %GenLSP.ErrorResponse{code: code}} = handle(action, context(1))
      assert code == ErrorCodes.invalid_params()
    end

    test "rejects an out-of-bounds character with InvalidParams" do
      # line 1 is "arg1" (4 chars); character 9999 is past its end
      action =
        deferred_action(%{
          "version" => 1,
          "range" => %{
            "start" => %{"line" => 1, "character" => 9999},
            "end" => %{"line" => 2, "character" => 1}
          }
        })

      assert {:ok, %GenLSP.ErrorResponse{code: code}} = handle(action, context(1))
      assert code == ErrorCodes.invalid_params()
    end

    test "rejects a reversed range with InvalidParams" do
      action =
        deferred_action(%{
          "version" => 1,
          "range" => %{
            "start" => %{"line" => 2, "character" => 1},
            "end" => %{"line" => 1, "character" => 1}
          }
        })

      assert {:ok, %GenLSP.ErrorResponse{code: code}} = handle(action, context(1))
      assert code == ErrorCodes.invalid_params()
    end

    test "rejects a missing module with InvalidParams" do
      action = deferred_action(%{"version" => 1, "module" => nil})

      assert {:ok, %GenLSP.ErrorResponse{code: code}} = handle(action, context(1))
      assert code == ErrorCodes.invalid_params()
    end
  end

  describe "actions that are not ours" do
    test "echoes back an action without a resolvable data payload" do
      action = %Structures.CodeAction{title: "Some other action", data: nil}

      assert {:ok, ^action} = handle(action, nil)
    end

    test "echoes back a foreign action even when a document context is present" do
      action = %Structures.CodeAction{
        title: "Quick fix",
        edit: %Structures.WorkspaceEdit{changes: %{}},
        data: %{"provider" => "something-else"}
      }

      assert {:ok, ^action} = handle(action, context(1))
    end
  end
end
