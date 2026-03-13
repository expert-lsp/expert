defmodule Expert.Provider.Handlers.GoToDefinitionTest do
  use ExUnit.Case, async: false

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Location
  alias GenLSP.Requests.TextDocumentDefinition
  alias GenLSP.Structures

  setup_all do
    project = project(:navigations)

    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.ActiveProjects, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    Expert.Configuration.new() |> Expert.Configuration.set()

    EngineApi.register_listener(project, self(), [
      project_compiled(),
      project_index_ready()
    ])

    EngineApi.schedule_compile(project, true)
    assert_receive project_compiled(), 5000
    assert_receive project_index_ready(), 5000

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
    Expert.ActiveProjects.add_projects([project])
    Handlers.GoToDefinition.handle(request)
  end

  describe "go to definition" do
    setup [:with_referenced_file]

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
