defmodule Expert.Test.MixReloadSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.Project.Store
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Notifications
  alias GenLSP.Structures

  def with_engine_services(%{tmp_dir: tmp_dir}) do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!(Store)
    start_supervised!(Forge.NodePortMapper)
    start_supervised!({Document.Store, []})
    {:ok, root: Path.join(tmp_dir, "project")}
  end

  def mix_source(version \\ "0.1.0", paths \\ ["lib"]) do
    """
    defmodule SavedReload.MixProject do
      use Mix.Project
      def project do
        [app: :saved_reload, version: #{inspect(version)},
         elixirc_paths: #{inspect(paths)}, deps: []]
      end
    end
    """
  end

  def write(root, relative_path, source) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  def start_project(root, source \\ mix_source(), filename \\ "mix.exs") do
    write(root, filename, source)
    project = root |> Document.Path.to_uri() |> Project.new()
    assert project.kind == :mix
    start_supervised!({Expert.EngineSupervisor, project})
    assert {:ok, _node, node_pid} = EngineNode.start(project)
    :ok = Store.add_projects([project])
    assert Store.transition(project, :ready)

    :ok =
      EngineApi.register_listener(project, self(), [
        project_compiled(),
        project_diagnostics(),
        file_compiled(),
        file_diagnostics()
      ])

    build_pid = EngineApi.call(project, Process, :whereis, [Engine.Build])
    assert is_pid(build_pid)

    %{
      project: project,
      node_pid: node_pid,
      build_pid: build_pid,
      monitors: Enum.map([node_pid, build_pid], &Process.monitor/1)
    }
  end

  def initial_build(%{project: project} = context, status \\ :success) do
    :ok = EngineApi.schedule_compile(project, true)
    await_build(context, status)
  end

  def save(context, path, source, status \\ :success) do
    edit(path, source)
    File.write!(path, source)
    state = %Expert.State{initialized?: true}

    event = %Notifications.TextDocumentDidSave{
      params: %Structures.DidSaveTextDocumentParams{
        text_document: %Structures.TextDocumentIdentifier{uri: Document.Path.to_uri(path)}
      }
    }

    assert {:ok, ^state} = Expert.State.apply(state, event)
    await_build(context, status)
  end

  def edit(path, source) do
    uri = Document.Path.to_uri(path)

    if !Document.Store.open?(uri) do
      :ok = Document.Store.open(uri, File.read!(path), 0)
    end

    {:ok, document} =
      Document.Store.get_and_update(uri, fn document ->
        {:ok, uri |> Document.new(source, document.version + 1) |> Document.mark_dirty()}
      end)

    document
  end

  def await_build(%{project: project} = context, expected_status) do
    root_uri = project.root_uri

    assert_receive project_compiled(project: %Project{root_uri: ^root_uri}, status: status),
                   15_000

    assert_receive project_diagnostics(
                     project: %Project{root_uri: ^root_uri},
                     diagnostics: diagnostics
                   )

    assert status == expected_status, inspect({status, diagnostics}, pretty: true)
    assert_same_processes(context)
    diagnostics
  end

  def assert_same_processes(context) do
    assert Process.whereis(EngineNode.name(context.project)) == context.node_pid
    assert EngineApi.call(context.project, Process, :whereis, [Engine.Build]) == context.build_pid

    for ref <- context.monitors do
      refute_received {:DOWN, ^ref, :process, _, _}
    end
  end

  def eval(project, expression, bindings \\ []) do
    {result, _bindings} = EngineApi.call(project, Code, :eval_string, [expression, bindings])
    result
  end

  def config(project) do
    {:ok, config} = eval(project, "Engine.Mix.in_project(fn _ -> Mix.Project.config() end)")
    config
  end

  def assert_invalid(project) do
    assert %Project{kind: :mix, project_module: nil} =
             EngineApi.call(project, Engine, :get_project)

    assert {:error, :project_not_loaded} =
             eval(project, ~s[Engine.Mix.in_project(fn _ -> raise "invalid callback ran" end)])
  end

  def assert_diagnostic(diagnostics, path, message) do
    uri = Document.Path.to_uri(path)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.uri == uri and diagnostic.severity == :error and
               String.contains?(diagnostic.message, message)
           end),
           inspect(diagnostics, pretty: true)
  end
end
