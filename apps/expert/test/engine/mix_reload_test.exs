defmodule Engine.MixReloadTest do
  use ExUnit.Case, async: false
  use Patch

  import Expert.Test.MixReloadSupport
  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Forge.Document
  alias Forge.Project

  @moduletag :tmp_dir

  setup :with_engine_services

  test "a saved root changes the version and compiles the new elixirc_paths", %{root: root} do
    write(
      root,
      "extra/added.ex",
      "defmodule SavedReload.Added do\n def value, do: :new_path\nend"
    )

    context = start_project(root)
    project = context.project
    assert [] = initial_build(context)
    assert config(project)[:version] == "0.1.0"
    refute EngineApi.call(project, Code, :ensure_loaded?, [SavedReload.Added])

    assert [] =
             save(context, Project.mix_exs_path(project), mix_source("0.2.0", ["lib", "extra"]))

    assert config(project)[:version] == "0.2.0"
    assert config(project)[:elixirc_paths] == ["lib", "extra"]
    assert eval(project, "Forge.Project.config(Engine.get_project())[:version]") == "0.2.0"
    assert EngineApi.call(project, SavedReload.Added, :value) == :new_path
  end

  test "unsaved Mix text does not execute project code", %{root: root} do
    context = start_project(root)
    project = context.project
    assert [] = initial_build(context)
    path = Project.mix_exs_path(project)
    uri = Document.Path.to_uri(path)
    original = File.read!(path)
    sentinel = Path.join(root, "executed")

    source = "File.write!(#{inspect(sentinel)}, \"ran\")\nexit(1)\n" <> mix_source("0.2.0")
    document = edit(path, source)
    :ok = EngineApi.call(project, Engine.Build, :force_compile_document, [document])

    assert_receive file_compiled(uri: ^uri, status: :success)
    assert_receive file_diagnostics(uri: ^uri, diagnostics: [])
    refute File.exists?(sentinel)
    assert File.read!(path) == original
    assert config(project)[:version] == "0.1.0"
    assert_same_processes(context)
  end

  test "a saved project error reports diagnostics and a corrected save recovers", %{root: root} do
    context = start_project(root)
    project = context.project
    assert [] = initial_build(context)
    path = Project.mix_exs_path(project)

    diagnostics = save(context, path, "foo()\n" <> mix_source(), :error)
    assert_diagnostic(diagnostics, path, "undefined function foo/0")
    assert_invalid(project)

    document = Document.new(Document.Path.to_uri(Path.join(root, "lib/example.ex")), "1", 1)
    :ok = EngineApi.call(project, Engine.Build, :force_compile_document, [document])
    assert_receive file_compiled(status: :error)
    refute_receive file_diagnostics()

    assert [] = save(context, path, mix_source("0.3.0"))
    assert config(project)[:version] == "0.3.0"

    assert %Project{kind: :mix, project_module: SavedReload.MixProject} =
             EngineApi.call(project, Engine, :get_project)
  end

  test "umbrella child errors use the child URI and saved child configuration takes effect", %{
    root: root
  } do
    child_source =
      mix_source()
      |> String.replace("SavedReload.MixProject", "SavedReload.Child.MixProject")
      |> String.replace("app: :saved_reload", "app: :reload_child, build_path: \"../../_build\"")

    child_path = write(root, "apps/reload_child/mix.exs", child_source)

    context =
      start_project(root, """
      defmodule SavedReload.Umbrella.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0", deps: []]
      end
      """)

    project = context.project
    assert [] = initial_build(context)

    diagnostics =
      save(
        context,
        child_path,
        String.replace(child_source, "def project do", "def project do\n foo()"),
        :error
      )

    assert_diagnostic(diagnostics, child_path, "undefined function foo/0")

    write(
      root,
      "apps/reload_child/extra/added.ex",
      "defmodule SavedReload.ChildAdded do\n def value, do: :child\nend"
    )

    changed =
      child_source
      |> String.replace("0.1.0", "0.2.0")
      |> String.replace(~s(["lib"]), ~s(["lib", "extra"]))

    assert [] = save(context, child_path, changed)

    assert {:ok, "0.2.0"} =
             eval(project, """
             Engine.Mix.in_project(fn _ ->
               Mix.Project.in_project(:reload_child, "apps/reload_child", fn _ ->
                 Mix.Project.config()[:version]
               end)
             end)
             """)

    assert EngineApi.call(project, SavedReload.ChildAdded, :value) == :child
  end

  test "an invalid root at startup stays a Mix project and recovers on save", %{root: root} do
    context = start_project(root, "exit(1)\n")
    project = context.project
    path = Project.mix_exs_path(project)

    assert %Project{kind: :mix, project_module: nil} =
             EngineApi.call(project, Engine, :get_project)

    diagnostics = initial_build(context, :error)
    assert_diagnostic(diagnostics, path, "mix.exs compilation exited: 1")
    assert_invalid(project)

    assert [] = save(context, path, mix_source("0.4.0"))
    assert config(project)[:version] == "0.4.0"
  end

  test "a corrected save clears Mix diagnostics published to the editor", %{root: root} do
    Expert.Test.Protocol.TransportSupport.with_patched_transport()
    context = start_project(root)
    start_supervised!({Expert.Project.Diagnostics, context.project})
    assert [] = initial_build(context)
    path = Project.mix_exs_path(context.project)
    uri = Document.Path.to_uri(path)

    assert [_ | _] = save(context, path, "exit(1)", :error)

    assert_receive {:transport,
                    %GenLSP.Notifications.TextDocumentPublishDiagnostics{
                      params: %{
                        uri: ^uri,
                        diagnostics: [%{message: "mix.exs compilation exited: 1"}]
                      }
                    }}

    assert [] = save(context, path, mix_source())

    assert_receive {:transport,
                    %GenLSP.Notifications.TextDocumentPublishDiagnostics{
                      params: %{uri: ^uri, diagnostics: []}
                    }}
  end
end
