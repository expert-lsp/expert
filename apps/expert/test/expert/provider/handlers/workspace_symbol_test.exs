defmodule Expert.Provider.Handlers.WorkspaceSymbolTest do
  use ExUnit.Case, async: false

  alias Expert.Configuration
  alias Expert.Configuration.WorkspaceSymbols
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Protocol.Id
  alias Expert.Provider.Handlers
  alias Forge.EngineApi.Messages
  alias Forge.Test.Fixtures
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Messages

  setup_all do
    project = Fixtures.project()

    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.ActiveProjects, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    :ok =
      EngineApi.register_listener(project, self(), [
        Messages.project_compiled(),
        Messages.project_index_ready()
      ])

    assert_receive Messages.project_compiled(), 5000
    assert_receive Messages.project_index_ready(), 5000

    Expert.ActiveProjects.add_projects([project])

    {:ok, project: project}
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  describe "handle/1 with default configuration (minQueryLength: 2)" do
    test "returns empty list when query is empty", %{project: _project} do
      Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("")

      {:ok, symbols} = Handlers.WorkspaceSymbol.handle(request)

      assert symbols == []
    end

    test "returns empty list when query is single character", %{project: _project} do
      Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("a")

      {:ok, symbols} = Handlers.WorkspaceSymbol.handle(request)

      assert symbols == []
    end

    test "returns symbols when query meets minQueryLength", %{project: _project} do
      Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("Pro")

      {:ok, [_ | _] = symbols} = Handlers.WorkspaceSymbol.handle(request)

      assert Enum.any?(symbols, &String.contains?(&1.name, "Project"))
    end
  end

  describe "handle/1 with minQueryLength: 0" do
    test "returns symbols when query is empty", %{project: _project} do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 0}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("")

      {:ok, [_ | _]} = Handlers.WorkspaceSymbol.handle(request)
    end

    test "returns symbols when query is single character", %{project: _project} do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 0}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("a")

      {:ok, [_ | _]} = Handlers.WorkspaceSymbol.handle(request)
    end
  end

  describe "handle/1 with minQueryLength: 1" do
    test "returns empty list when query is empty", %{project: _project} do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 1}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("")

      {:ok, symbols} = Handlers.WorkspaceSymbol.handle(request)

      assert symbols == []
    end

    test "returns symbols when query is single character", %{project: _project} do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 1}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, request} = build_request("F")

      {:ok, [_ | _]} = Handlers.WorkspaceSymbol.handle(request)
    end
  end

  defp build_request(query) do
    request = %Requests.WorkspaceSymbol{
      id: Id.next(),
      params: %Structures.WorkspaceSymbolParams{
        query: query
      }
    }

    Convert.to_native(request)
  end
end
