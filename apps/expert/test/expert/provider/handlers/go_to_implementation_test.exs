defmodule Expert.Provider.Handlers.GoToImplementationTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers.GoToImplementation
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentImplementation
  alias GenLSP.Structures

  setup_all do
    start_supervised!(Expert.Application.document_store_child_spec())
    :ok
  end

  test "returns engine implementation locations" do
    project = project()
    uri = Document.Path.ensure_uri(file_path(project, "lib/project.ex"))
    document = Document.new(uri, "Example", 1)
    context = Context.new(uri, document, project)
    location = :location

    patch(EngineApi, :implementation, {:ok, [location]})

    assert {:ok, [^location]} = GoToImplementation.handle(request(document), context)
  end

  test "returns an empty list when the engine fails" do
    project = project()
    uri = Document.Path.ensure_uri(file_path(project, "lib/project.ex"))
    document = Document.new(uri, "Example", 1)
    context = Context.new(uri, document, project)

    patch(EngineApi, :implementation, {:error, :failed})

    assert {:ok, []} = GoToImplementation.handle(request(document), context)
  end

  defp request(document) do
    request = %TextDocumentImplementation{
      id: Expert.Protocol.Id.next(),
      params: %Structures.ImplementationParams{
        text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
        position: %Structures.Position{line: 0, character: 1}
      }
    }

    {:ok, request} = Convert.to_native(request, document)
    request
  end
end
