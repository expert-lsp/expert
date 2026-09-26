defmodule Expert.Provider.Handlers.CodeActionTest do
  use ExUnit.Case, async: false

  import Expert.Test.ConfigurationSupport
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
  alias GenLSP.Requests.TextDocumentCodeAction
  alias GenLSP.Structures

  @project_ready_timeout :timer.seconds(15)

  setup_all do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    project = project(:navigations)

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

    EngineApi.register_listener(project, self(), [project_compiled(), project_index_ready()])
    EngineApi.schedule_compile(project, true)

    assert_receive project_compiled(), @project_ready_timeout
    Indexer.refresh(project)
    assert_receive project_index_ready(project: ^project), @project_ready_timeout

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

  def handle(request, project) do
    document = Document.Container.context_document(request, nil)
    context = Context.new(document.uri, document, project)
    Handlers.CodeAction.handle(request, context)
  end

  describe "handle code actions" do
    test "returns code actions for a given range", %{project: project} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, {4, 4}, {4, 31})

      assert {:ok, _actions} = handle(request, project)
    end
  end

  describe "codeAction/resolve" do
    defp deferred_refactors(actions) do
      Enum.filter(
        actions,
        &match?(%Structures.CodeAction{data: %{"provider" => "refactor"}}, &1)
      )
    end

    # build_request opens the document temporarily; on a slow runner that window
    # can lapse during handle/2's engine round-trip, unloading it before we build
    # the resolve context. Re-acquire it (open_temporary returns the still-open
    # doc or re-opens it at the same version) so the context holds a live document
    # regardless of the store's temporary lifecycle.
    defp resolve_document(uri) do
      {:ok, document} = Document.Store.open_temporary(uri)
      document
    end

    test "defers refactor edits and resolves them on demand", %{project: project} do
      put_resolve_support(%{properties: ["edit"]})

      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, {4, 4}, {4, 4})

      assert {:ok, actions} = handle(request, project)

      deferred = deferred_refactors(actions)

      assert deferred != []
      assert Enum.all?(deferred, &is_nil(&1.edit))

      action = Enum.find(deferred, &(&1.title == "Introduce pipe")) || hd(deferred)

      resolve_request = %GenLSP.Requests.CodeActionResolve{
        id: Expert.Protocol.Id.next(),
        params: action
      }

      uri = action.data["uri"]
      context = Context.new(uri, resolve_document(uri), project)

      assert {:ok, %Structures.CodeAction{} = resolved} =
               Handlers.CodeActionResolve.handle(resolve_request, context)

      assert %Structures.WorkspaceEdit{changes: %{^uri => %Document.Changes{edits: edits}}} =
               resolved.edit

      assert edits != []
    end

    test "keeps eager edits for clients without resolve support", %{project: project} do
      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, {4, 4}, {4, 4})

      assert {:ok, actions} = handle(request, project)

      refactors = Enum.filter(actions, &(&1.kind == "refactor.rewrite"))

      assert refactors != []
      assert Enum.all?(refactors, &(not is_nil(&1.edit)))
      assert Enum.all?(actions, &is_nil(&1.data))
    end

    test "rejects resolve for a stale document version", %{project: project} do
      put_resolve_support(%{properties: ["edit"]})

      uses_file_path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(uses_file_path, {4, 4}, {4, 4})

      assert {:ok, actions} = handle(request, project)
      assert [%Structures.CodeAction{} = action | _] = deferred_refactors(actions)

      stale_action = %Structures.CodeAction{
        action
        | data: Map.update!(action.data, "version", &(&1 + 1))
      }

      resolve_request = %GenLSP.Requests.CodeActionResolve{
        id: Expert.Protocol.Id.next(),
        params: stale_action
      }

      uri = action.data["uri"]
      context = Context.new(uri, resolve_document(uri), project)

      assert {:ok, %GenLSP.ErrorResponse{code: code}} =
               Handlers.CodeActionResolve.handle(resolve_request, context)

      assert code == GenLSP.Enumerations.LSPErrorCodes.content_modified()
    end
  end
end
