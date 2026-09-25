defmodule Expert.Provider.Handlers.GoToDeclarationTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers.GoToDeclaration
  alias Expert.State
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentDeclaration
  alias GenLSP.Structures.DeclarationParams
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.TextDocumentIdentifier

  setup do
    start_supervised!(Expert.Application.document_store_child_spec())
    Expert.Configuration.new() |> Expert.Configuration.set()
    on_exit(fn -> :persistent_term.erase(Expert.Configuration) end)
  end

  test "forwards declaration requests to the project engine" do
    project = project()
    document = Document.new("file:///declaration.ex", "def run, do: :ok", 3)
    context = Context.new(document.uri, document, project)

    lsp_request =
      %TextDocumentDeclaration{
        id: 1,
        params: %DeclarationParams{
          text_document: %TextDocumentIdentifier{uri: document.uri},
          position: %Position{line: 0, character: 4}
        }
      }

    assert {:ok, request} = Convert.to_native(lsp_request, document)
    position = request.params.position

    patch(EngineApi, :declaration, fn ^project, ^document, ^position -> {:ok, nil} end)

    assert {:ok, nil} = GoToDeclaration.handle(request, context)
  end

  test "advertises declaration support" do
    assert State.initialize_result().capabilities.declaration_provider
  end
end
