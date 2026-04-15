defmodule Expert.Provider.Handlers.FormattingTest do
  use Forge.Test.CodeMod.Case, enable_ast_conversion: false

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Forge.Document

  def document(file_uri, text) do
    Document.new(file_uri, text, 1)
  end

  def with_real_project(%{project: project}) do
    {:ok, _} =
      start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

    {:ok, _} = start_supervised(Expert.EngineBuilds)
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    {:ok, _} = start_supervised({Expert.EngineSupervisor, project})
    {:ok, _, _} = EngineNode.start(project)
    EngineApi.register_listener(project, self(), [:all])
    :ok
  end

  setup do
    project = project()
    Engine.set_project(project)
    {:ok, project: project}
  end

  describe "emitting diagnostics" do
    setup [:with_real_project]

    test "it should emit diagnostics when a syntax error occurs", %{project: project} do
      text = ~q[
        def foo(a, ) do
        end
        ]
      document = document("file:///file.ex", text)
      EngineApi.format(project, document)

      assert_receive file_diagnostics(diagnostics: [diagnostic]), 500
      assert diagnostic.message =~ "syntax error"
    end
  end
end
