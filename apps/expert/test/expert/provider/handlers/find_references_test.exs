defmodule Expert.Provider.Handlers.FindReferencesTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.CodeIntelligence.References
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Expert.Search.Indexer.Manifest
  alias Expert.Search.Indexer.ManifestStore
  alias Expert.Search.Store
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Subject
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Structures

  setup_all do
    start_supervised(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.Project.Store, []})
    :ok
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    Expert.Configuration.new() |> Expert.Configuration.set()
    project = project(:navigations)
    path = file_path(project, Path.join("lib", "my_definition.ex"))
    uri = Document.Path.ensure_uri(path)
    {:ok, project: project, uri: uri}
  end

  def build_request(path, line, char) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %TextDocumentReferences{
        id: Expert.Protocol.Id.next(),
        params: %Structures.ReferenceParams{
          context: %Structures.ReferenceContext{
            include_declaration: true
          },
          text_document: %Structures.TextDocumentIdentifier{uri: uri},
          position: %Structures.Position{line: line, character: char}
        }
      }

      Convert.to_native(req)
    end
  end

  def handle(request, project) do
    Expert.Project.Store.add_projects([project])
    document = Document.Container.context_document(request, nil)
    context = Context.new(document.uri, document, project)
    Handlers.FindReferences.handle(request, context)
  end

  describe "find references" do
    test "returns locations that the entity returns", %{project: project, uri: uri} do
      assert Handlers.FindReferences.requires_engine?() == false
      project_uri = project.root_uri

      patch(References, :references, fn %{root_uri: ^project_uri},
                                        %Analysis{document: document},
                                        _position,
                                        _,
                                        false ->
        locations = [
          Location.new(
            Document.Range.new(
              Document.Position.new(document, 1, 5),
              Document.Position.new(document, 1, 10)
            ),
            Document.Path.to_uri("/path/to/file.ex")
          )
        ]

        locations
      end)

      {:ok, request} = build_request(uri, 5, 6)

      assert {:ok, [%Location{} = location]} = handle(request, project)
      assert location.uri =~ "file.ex"
    end

    test "returns nothing if the entity can't resolve it", %{project: project, uri: uri} do
      patch(References, :references, nil)

      {:ok, request} = build_request(uri, 1, 5)

      assert {:ok, nil} == handle(request, project)
    end

    test "does not resolve a literal as its enclosing function call", %{project: project} do
      patch(EngineApi, :resolve_entity, fn _, _, _ -> flunk("called the Engine") end)

      path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(path, 4, 25)
      document = Document.Container.context_document(request, nil)

      entry = %Entry{
        subject: Subject.mfa(MyDefinition, :greet, 1),
        type: {:function, :usage},
        subtype: :reference,
        path: path,
        range:
          Document.Range.new(
            Document.Position.new(document, 5, 5),
            Document.Position.new(document, 5, 32)
          )
      }

      patch(Store, :all, {:ok, [entry]})

      assert {:ok, []} = handle(request, project)
    end

    test "finds references from a function declaration before the Engine is ready", %{
      project: project,
      uri: uri
    } do
      path = Document.Path.ensure_path(uri)
      {:ok, request} = build_request(path, 16, 7)
      document = Document.Container.context_document(request, nil)
      position = request.params.position

      range =
        Document.Range.new(
          Document.Position.new(document, position.line, 3),
          Document.Position.new(document, position.line, 20)
        )

      definition = %Entry{
        subject: Subject.mfa(MyDefinition, :greet, 1),
        type: {:function, :public},
        subtype: :definition,
        path: path,
        range: range
      }

      reference = %Entry{
        definition
        | type: {:function, :usage},
          subtype: :reference,
          path: "/reference.ex"
      }

      {:ok, manifest_entry} = Manifest.Entry.source(path)
      patch(ManifestStore, :load, {:ok, Manifest.new([manifest_entry])})
      patch(Store, :all, {:ok, [definition]})
      patch(Store, :prefix, {:ok, [reference]})

      assert {:ok, [%Location{} = location]} = handle(request, project)
      assert Location.uri(location) == Document.Path.ensure_uri(reference.path)
    end

    test "uses the Engine instead of stale entries for a dirty document", %{project: project} do
      test_pid = self()
      path = file_path(project, Path.join("lib", "uses.ex"))
      uri = Document.Path.ensure_uri(path)

      :ok =
        Document.Store.open(
          uri,
          """
          defmodule Navigations.Uses do
            def call do
              New.foo()
            end
          end
          """,
          2
        )

      on_exit(fn -> Document.Store.close(uri) end)
      {:ok, request} = build_request(path, 2, 9)
      document = Document.Container.context_document(request, nil)

      stale_entry = %Entry{
        subject: Subject.mfa(Old, :foo, 0),
        type: {:function, :usage},
        subtype: :reference,
        path: path,
        range:
          Document.Range.new(
            Document.Position.new(document, 3, 5),
            Document.Position.new(document, 3, 14)
          )
      }

      patch(Store, :all, {:ok, [stale_entry]})
      patch(Store, :prefix, {:ok, [stale_entry]})

      patch(EngineApi, :resolve_entity, fn ^project, _analysis, _position ->
        send(test_pid, :engine_fallback)
        {:error, :unresolved}
      end)

      Expert.Project.Store.add_projects([project])
      assert Expert.Project.Store.transition(project, :ready)
      on_exit(fn -> Expert.Project.Store.transition(project, :pending) end)

      assert {:ok, []} = handle(request, project)
      assert_receive :engine_fallback
    end
  end
end
