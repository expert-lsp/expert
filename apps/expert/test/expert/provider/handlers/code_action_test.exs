defmodule Expert.Provider.Handlers.CodeActionTest do
  use ExUnit.Case, async: false

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentCodeAction
  alias GenLSP.Structures

  setup_all do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    project = project(:navigations)

    start_supervised!({Expert.ActiveProjects, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    Expert.ActiveProjects.set_projects([project])
    Expert.Configuration.new() |> Expert.Configuration.set()

    EngineApi.register_listener(project, self(), [project_compiled()])
    EngineApi.schedule_compile(project, true)

    assert_receive project_compiled(), 5000

    {:ok, project: project}
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  def build_request(path, {start_line, start_char}, {end_line, end_char}) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %TextDocumentCodeAction{
        id: Expert.Protocol.Id.next(),
        params: %Structures.CodeActionParams{
          text_document: %Structures.TextDocumentIdentifier{uri: uri},
          context: %Structures.CodeActionContext{
            trigger_kind: 1,
            only: nil,
            diagnostics: [
              %Structures.Diagnostic{
                range: %Structures.Range{
                  start: %Structures.Position{line: start_line, character: start_char},
                  end: %Structures.Position{line: end_line, character: end_char}
                },
                message: "Test diagnostic",
                severity: 1,
                source: "TestSource"
              }
            ]
          },
          range: %Structures.Range{
            start: %Structures.Position{line: start_line, character: start_char},
            end: %Structures.Position{line: end_line, character: end_char}
          }
        }
      }

      Convert.to_native(req)
    end
  end

  def handle(request, _project) do
    Handlers.CodeAction.handle(request)
  end

  describe "handle code actions" do
    test "returns code actions for a given range", %{project: project} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, {4, 4}, {4, 31})

      assert {:ok, _actions} = handle(request, project)
    end
  end
end
