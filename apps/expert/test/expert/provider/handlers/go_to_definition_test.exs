defmodule Expert.Provider.Handlers.GoToDefinitionTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Expert.Project.Indexer
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Expert.Search.Store
  alias Forge.Document
  alias Forge.Document.Location
  alias GenLSP.Requests.TextDocumentDefinition
  alias GenLSP.Structures

  @project_compile_timeout :timer.seconds(15)
  @project_index_timeout :timer.seconds(30)

  setup_all do
    project = project(:navigations)

    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({EngineSupervisor, project})
    {:ok, _, _} = EngineNode.start(project)

    backend = Store.backend()
    start_supervised!({backend, project})
    start_supervised!({Store, [project, backend]})
    start_supervised!({Expert.Search.Indexer.ModuleRegistry, project})
    start_supervised!({Task.Supervisor, name: Indexer.task_supervisor_name(project)})
    start_supervised!({Indexer, project})

    Expert.Project.Store.set_projects([project])
    Expert.Project.Store.transition(project, :ready)

    Expert.Configuration.new() |> Expert.Configuration.set()

    EngineApi.register_listener(project, self(), [
      project_compiled(),
      project_index_ready()
    ])

    EngineApi.schedule_compile(project, true)
    assert_receive project_compiled(), @project_compile_timeout
    Indexer.refresh(project)
    assert_receive project_index_ready(project: ^project), @project_index_timeout

    {:ok, project: project}
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  defp with_referenced_file(%{project: project}) do
    path = file_path(project, Path.join("lib", "my_definition.ex"))
    %{uri: Document.Path.ensure_uri(path)}
  end

  def build_request(path, line, char) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %TextDocumentDefinition{
        id: Expert.Protocol.Id.next(),
        params: %Structures.DefinitionParams{
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
    Handlers.GoToDefinition.handle(request, context)
  end

  describe "go to definition" do
    setup [:with_referenced_file]

    test "uses the index before the Engine is ready", %{
      project: project,
      uri: referenced_uri
    } do
      assert Handlers.GoToDefinition.requires_engine?() == false
      patch(EngineApi, :definition, fn _, _, _ -> flunk("called the Engine") end)

      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 4, 17)

      assert {:ok, %Location{} = location} = handle(request, project)
      assert Location.uri(location) == referenced_uri
    end

    test "finds a local variable before the Engine is ready", %{project: project} do
      patch(EngineApi, :definition, fn _, _, _ -> flunk("called the Engine") end)

      path = file_path(project, Path.join("lib", "my_definition.ex"))
      {:ok, request} = build_request(path, 17, 16)

      assert {:ok, %Location{} = location} = handle(request, project)
      assert Location.uri(location) == Document.Path.ensure_uri(path)
    end

    test "uses the Engine after an index miss when it is ready", %{project: project} do
      test_pid = self()
      assert Expert.Project.Store.transition(project, :ready)
      on_exit(fn -> Expert.Project.Store.transition(project, :pending) end)

      patch(EngineApi, :definition, fn ^project, _document, _position ->
        send(test_pid, :engine_fallback)
        {:ok, nil}
      end)

      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 8, 7)

      assert {:ok, nil} = handle(request, project)
      assert_receive :engine_fallback
    end

    test "finds user-defined functions", %{project: project, uri: referenced_uri} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 4, 17)

      {:ok, %Location{} = location} = handle(request, project)
      assert Location.uri(location) == referenced_uri
    end

    test "finds user-defined modules", %{project: project, uri: referenced_uri} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 4, 4)

      {:ok, %Location{} = location} = handle(request, project)
      assert Location.uri(location) == referenced_uri
    end

    test "does not find built-in functions", %{project: project} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 8, 7)

      {:ok, nil} = handle(request, project)
    end

    test "does not find built-in modules", %{project: project} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, 8, 4)

      {:ok, nil} = handle(request, project)
    end
  end
end
