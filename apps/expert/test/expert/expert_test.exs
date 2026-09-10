defmodule ExpertTest do
  use ExUnit.Case, async: false
  use Forge.Test.EventualAssertions
  use Patch

  import Forge.Test.Fixtures
  import GenLSP.Test

  alias Forge.Document
  alias Forge.Project

  setup_all do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!({Task.Supervisor, name: :expert_task_queue})
    start_supervised!({DynamicSupervisor, name: Expert.DynamicSupervisor})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})

    project_root = fixtures_path() |> Path.join("workspace_folders")

    main_project =
      project_root
      |> Path.join("main")
      |> Document.Path.to_uri()
      |> Project.new()

    secondary_project =
      project_root
      |> Path.join("secondary")
      |> Document.Path.to_uri()
      |> Project.new()

    nested_root_path = fixtures_path() |> Path.join("nested_projects")

    nested_root_project =
      nested_root_path
      |> Document.Path.to_uri()
      |> Project.new()

    nested_subproject =
      nested_root_path
      |> Path.join("subproject")
      |> Document.Path.to_uri()
      |> Project.new()

    [
      project_root: project_root,
      main_project: main_project,
      secondary_project: secondary_project,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    ]
  end

  setup do
    # Clear any leftover configuration from previous tests
    :persistent_term.erase(Expert.Configuration)
    Forge.Workspace.set_workspace(nil)

    # window/logMessage is emitted by a Logger handler; keep :info enabled
    # so integration assertions can observe those notifications.
    # The :default console handler is suppressed to avoid polluting test output.
    Expert.Logging.WindowLogHandler.attach()
    Logger.configure(level: :info)
    :logger.update_handler_config(:default, :level, :none)

    on_exit(fn ->
      Forge.Workspace.set_workspace(nil)
      Logger.configure(level: :none)
      :logger.update_handler_config(:default, :level, :all)
    end)

    # NOTE(doorgan): repeatedly starting and stopping nodes in tests produces some
    # erratic behavior where sometimes some tests won't run. This somewhat mitigates
    # that.
    test_pid = self()

    patch(Expert.Project.Supervisor, :start, fn project ->
      send(test_pid, {:project_alive, project.root_uri})
      {:ok, nil}
    end)

    patch(Expert.Project.Supervisor, :stop, fn project ->
      send(test_pid, {:project_stopped, project.root_uri})
      :ok
    end)

    start_supervised!({Expert.Project.Store, []})

    server =
      server(Expert,
        task_supervisor: :expert_task_queue,
        dynamic_supervisor: Expert.DynamicSupervisor
      )

    client = client(server)

    assert Process.alive?(server.lsp)

    [server: server, client: client]
  end

  def initialize_request(root_path, opts \\ []) do
    id = opts[:id] || 1
    projects = Keyword.get(opts, :projects, [])

    root_uri =
      Keyword.get_lazy(opts, :root_uri, fn ->
        if root_path, do: Document.Path.to_uri(root_path)
      end)

    workspace_folders =
      if not is_nil(projects) do
        Enum.map(projects, fn project ->
          %{uri: project.root_uri, name: Project.name(project)}
        end)
      end

    %{
      method: "initialize",
      id: id,
      jsonrpc: "2.0",
      params: %{
        rootUri: root_uri,
        initializationOptions: %{},
        capabilities: %{
          workspace: %{
            workspaceFolders: true
          },
          window: %{
            showMessage: %{}
          }
        },
        workspaceFolders: workspace_folders
      }
    }
  end

  def initialized_notification do
    %{
      method: "initialized",
      jsonrpc: "2.0",
      params: %{}
    }
  end

  def assert_project_alive?(project) do
    expected_uri = project.root_uri
    assert_receive {:project_alive, ^expected_uri}
  end

  def assert_project_stopped?(project) do
    expected_uri = project.root_uri
    assert_receive {:project_stopped, ^expected_uri}
  end

  describe "initialize request" do
    test "starts a project at the initial workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, %{
        "capabilities" => %{
          "implementationProvider" => true,
          "workspace" => %{"workspaceFolders" => %{"supported" => true}}
        }
      })

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == main_project.root_uri

      assert_project_alive?(main_project)
    end

    test "uses the umbrella root for an initial sub-app workspace folder", %{
      client: client
    } do
      umbrella_root = Path.join(fixtures_path(), "umbrella")
      sub_app_path = Path.join([umbrella_root, "apps", "first"])
      umbrella_project = umbrella_root |> Document.Path.to_uri() |> Project.new()

      assert :ok =
               request(
                 client,
                 initialize_request(sub_app_path, id: 1, projects: nil)
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(umbrella_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == umbrella_project.root_uri

      assert_project_alive?(umbrella_project)
    end

    test "uses the umbrella root for an initial custom apps_path sub-app workspace folder",
         %{
           client: client
         } do
      umbrella_root = Path.join(fixtures_path(), "umbrella_custom_apps_path")
      sub_app_path = Path.join([umbrella_root, "packages", "first"])
      umbrella_project = umbrella_root |> Document.Path.to_uri() |> Project.new()

      assert :ok =
               request(
                 client,
                 initialize_request(sub_app_path, id: 1, projects: nil)
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(umbrella_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == umbrella_project.root_uri

      assert_project_alive?(umbrella_project)
    end
  end

  describe "workspace folders" do
    test "starts project nodes when adding workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_project_1] = Expert.Project.Store.projects()

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [
                         %{uri: secondary_project.root_uri, name: secondary_project.root_uri}
                       ],
                       removed: []
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_, _] = projects = Expert.Project.Store.projects()

      for project <- projects do
        assert project.root_uri in [main_project.root_uri, secondary_project.root_uri]
        assert_project_alive?(project)
      end
    end

    test "can remove workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == main_project.root_uri
      assert_project_alive?(main_project)

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [],
                       removed: [
                         %{uri: main_project.root_uri, name: main_project.root_uri}
                       ]
                     }
                   }
                 }
               )

      expected_message = "Stopping project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [] = Expert.Project.Store.projects()
      assert_project_stopped?(main_project)
    end

    test "removes tracked projects discovered inside a removed container workspace folder", %{
      client: client,
      project_root: project_root,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil)
               )

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      file_uri = Path.join([secondary_project.root_uri, "lib", "secondary.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == secondary_project.root_uri
      assert_project_alive?(secondary_project)

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [],
                       removed: [
                         %{
                           uri: Document.Path.to_uri(project_root),
                           name: Document.Path.to_uri(project_root)
                         }
                       ]
                     }
                   }
                 }
               )

      expected_message = "Stopping project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [] = Expert.Project.Store.projects()
      assert_project_stopped?(secondary_project)
    end

    test "supports missing workspace_folders in the request", %{
      client: client,
      project_root: project_root
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil, root_uri: nil)
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      assert [] = Expert.Project.Store.projects()
    end

    test "creates a workspace when rootUri is nil and workspaceFolders are present", %{
      client: client,
      project_root: project_root,
      main_project: main_project,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root,
                   id: 1,
                   root_uri: nil,
                   projects: [main_project, secondary_project]
                 )
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      assert %Forge.Workspace{workspace_folders: workspace_folders} =
               Forge.Workspace.get_workspace()

      assert Enum.sort(workspace_folders) ==
               Enum.sort([
                 Forge.Project.root_path(main_project),
                 Forge.Project.root_path(secondary_project)
               ])

      assert [_, _] = projects = Expert.Project.Store.projects()

      assert Enum.sort(Enum.map(projects, & &1.root_uri)) ==
               Enum.sort([main_project.root_uri, secondary_project.root_uri])
    end

    test "creates a workspace from folder changes when none exists", %{
      client: client,
      project_root: project_root,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil)
               )

      assert_result(1, _)

      Forge.Workspace.set_workspace(nil)

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [
                         %{uri: secondary_project.root_uri, name: secondary_project.root_uri}
                       ],
                       removed: []
                     }
                   }
                 }
               )

      assert_project_alive?(secondary_project)

      assert %Forge.Workspace{workspace_folders: workspace_folders} =
               Forge.Workspace.get_workspace()

      assert workspace_folders == [Forge.Project.root_path(secondary_project)]
      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == secondary_project.root_uri
    end
  end

  describe "opening files" do
    test "discovers a project inside a container workspace folder when a file is opened", %{
      client: client,
      project_root: project_root,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil)
               )

      assert_result(1, _)
      assert [] = Expert.Project.Store.projects()

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      file_uri = Path.join([secondary_project.root_uri, "lib", "secondary.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == secondary_project.root_uri

      assert_project_alive?(secondary_project)
    end

    test "starts a project node when opening a file in a folder not specified as workspace folder",
         %{
           client: client,
           project_root: project_root,
           main_project: main_project,
           secondary_project: secondary_project
         } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      file_uri = Path.join([secondary_project.root_uri, "lib", "secondary.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_, _] = projects = Expert.Project.Store.projects()

      for project <- projects do
        assert project.root_uri in [main_project.root_uri, secondary_project.root_uri]
        assert_project_alive?(project)
      end
    end
  end

  describe "opening files in nested projects" do
    test "starts the subproject node when opening a file in a nested subproject", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path, id: 1, projects: nil, root_uri: nil)
               )

      assert_result(1, _)

      file_uri = Path.join([nested_subproject.root_uri, "lib", "subproject.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(nested_subproject)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == nested_subproject.root_uri
      refute project.root_uri == nested_root_project.root_uri

      assert_project_alive?(nested_subproject)
    end

    test "starts the root project node when opening a file outside nested subprojects", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path, id: 1, projects: nil, root_uri: nil)
               )

      assert_result(1, _)

      file_uri = Path.join([nested_root_project.root_uri, "lib", "nested_projects.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(nested_root_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == nested_root_project.root_uri

      assert_project_alive?(nested_root_project)
    end

    test "uses the subproject when both root and subproject are active", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path,
                   id: 1,
                   projects: [nested_root_project, nested_subproject]
                 )
               )

      assert_result(1, _)

      assert length(Expert.Project.Store.projects()) == 2

      file_uri = Path.join([nested_subproject.root_uri, "lib", "subproject.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      assert length(Expert.Project.Store.projects()) == 2
    end

    test "starts subproject when root is already active and file in subproject is opened", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path,
                   id: 1,
                   projects: [nested_root_project]
                 )
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)

      expected_message = "Started project node for #{Project.name(nested_root_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.Project.Store.projects()
      assert project.root_uri == nested_root_project.root_uri

      subproject_path = Path.join([nested_root_path, "subproject"])
      file_uri = Document.Path.to_uri(Path.join([subproject_path, "lib", "subproject.ex"]))

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      assert_eventually(
        case Document.Store.fetch(file_uri) do
          {:ok, _doc} -> true
          _ -> false
        end
      )

      expected_message = "Started project node for #{Project.name(nested_subproject)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert length(Expert.Project.Store.projects()) == 2
    end
  end

  describe "text document changes" do
    test "applies batched incremental changes against the preceding change", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      change = fn line, character, text ->
        position = %{line: line, character: character}
        %{text: text, range: %{start: position, end: position}}
      end

      patch(Expert.EngineApi, :broadcast, fn _project, _message -> :ok end)

      patch(Expert.EngineApi, :compile_document, fn _project, document ->
        send(test_pid, {:compiled_document, Document.to_string(document)})
        :ok
      end)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)
      assert Expert.Project.Store.transition(main_project, :ready)

      file_uri =
        Document.Path.to_uri(Path.join([project_root, "main", "lib", "sequential_changes.ex"]))

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: file_uri,
                     languageId: "elixir",
                     version: 1,
                     text: "defmodule Repro do"
                   }
                 }
               })

      assert_eventually(match?({:ok, _document}, Document.Store.fetch(file_uri)))

      assert :ok =
               notify(client, %{
                 method: "textDocument/didChange",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri, version: 2},
                   contentChanges: [
                     change.(0, 18, "\n"),
                     change.(1, 0, "d"),
                     change.(1, 1, "e"),
                     change.(1, 2, "f")
                   ]
                 }
               })

      expected = "defmodule Repro do\ndef"

      assert_receive {:compiled_document, compiled_document}
      assert compiled_document == expected
      assert {:ok, document} = Document.Store.fetch(file_uri)
      assert Document.to_string(document) == expected
    end

    test "compileOnType controls document compilation without suppressing change broadcasts", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :broadcast, fn _project, message ->
        send(test_pid, message)
        :ok
      end)

      patch(Expert.EngineApi, :compile_document, fn _project, document ->
        send(test_pid, {:compiled_document, document.version})
        :ok
      end)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)
      assert Expert.Project.Store.transition(main_project, :ready)

      file_uri = Document.Path.to_uri(Path.join([project_root, "main", "lib", "on_type.ex"]))

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: file_uri,
                     languageId: "elixir",
                     version: 1,
                     text: "defmodule OnType do\nend"
                   }
                 }
               })

      assert :ok =
               notify(client, %{
                 method: "textDocument/didChange",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri, version: 2},
                   contentChanges: [%{text: "defmodule OnType.Default do\nend"}]
                 }
               })

      assert_receive {:file_changed, ^file_uri, 2, 2, true}
      assert_receive {:compiled_document, 2}

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeConfiguration",
                   jsonrpc: "2.0",
                   params: %{settings: %{"compileOnType" => false}}
                 }
               )

      assert_eventually(not Expert.Configuration.compile_on_type?())

      assert :ok =
               notify(client, %{
                 method: "textDocument/didChange",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri, version: 3},
                   contentChanges: [%{text: "defmodule OnType.Disabled do\nend"}]
                 }
               })

      assert_receive {:file_changed, ^file_uri, 3, 3, true}
      refute_receive {:compiled_document, 3}, 100

      assert {:ok, document} = Document.Store.fetch(file_uri)
      assert document.version == 3
      assert Document.to_string(document) == "defmodule OnType.Disabled do\nend"
    end

    test "updates document store even when project engine is not active", %{
      client: client,
      project_root: project_root
    } do
      spy(Expert.EngineApi)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project ->
        {:ok, nil}
      end)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil, root_uri: nil)
               )

      assert_result(1, _)

      file_uri = Document.Path.to_uri(Path.join(project_root, "lib/test_file.ex"))
      initial_text = "defmodule Test do\nend"

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: file_uri,
                     languageId: "elixir",
                     version: 1,
                     text: initial_text
                   }
                 }
               })

      assert_eventually(
        case Document.Store.fetch(file_uri) do
          {:ok, doc} -> Document.to_string(doc) == initial_text
          _ -> false
        end
      )

      new_text = "defmodule Updated do\nend"

      assert :ok =
               notify(client, %{
                 method: "textDocument/didChange",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri, version: 2},
                   contentChanges: [%{text: new_text}]
                 }
               })

      assert_eventually(
        case Document.Store.fetch(file_uri) do
          {:ok, updated_doc} ->
            updated_doc.version == 2 and Document.to_string(updated_doc) == new_text

          _ ->
            false
        end
      )

      refute_any_call(Expert.EngineApi.broadcast())
      refute_any_call(Expert.EngineApi.compile_document())
    end
  end

  describe "text document save" do
    test "didSave schedules compile when project engine is ready", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :schedule_compile, fn project, false ->
        send(test_pid, {:scheduled_compile, project.root_uri})
        :ok
      end)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)
      assert Expert.Project.Store.transition(main_project, :ready)

      file_uri = Document.Path.to_uri(Path.join([project_root, "main", "lib", "ready_save.ex"]))
      initial_text = "defmodule ReadySave do\nend"

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: file_uri,
                     languageId: "elixir",
                     version: 1,
                     text: initial_text
                   }
                 }
               })

      assert :ok =
               notify(client, %{
                 method: "textDocument/didSave",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri}
                 }
               })

      assert_receive {:scheduled_compile, root_uri}
      assert root_uri == main_project.root_uri
    end

    test "didSave does not schedule compile while project engine is pending", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.Project.Supervisor, :ensure_node_started, fn project ->
        send(test_pid, {:engine_start_attempted, self(), project.root_uri})

        receive do
          :release_engine_start -> {:ok, nil}
        after
          1_000 -> {:ok, nil}
        end
      end)

      patch(Expert.EngineApi, :schedule_compile, fn project, force? ->
        send(test_pid, {:scheduled_compile, project.root_uri, force?})
        :ok
      end)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())
      assert_request(client, "client/registerCapability", fn _params -> nil end)
      assert_receive {:engine_start_attempted, engine_task, _root_uri}

      file_uri = Document.Path.to_uri(Path.join([project_root, "main", "lib", "pending_save.ex"]))
      initial_text = "defmodule PendingSave do\nend"

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: file_uri,
                     languageId: "elixir",
                     version: 1,
                     text: initial_text
                   }
                 }
               })

      assert :ok =
               notify(client, %{
                 method: "textDocument/didSave",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: file_uri}
                 }
               })

      refute_receive {:scheduled_compile, _, _}, 100
      send(engine_task, :release_engine_start)
    end

    test "didSave does not crash when file is not in any active project", %{
      client: client,
      project_root: project_root
    } do
      spy(Expert.EngineApi)

      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [])
               )

      assert_result(1, _)

      scratch_path = Path.join(project_root, "scratch")
      File.mkdir_p!(scratch_path)
      File.write!(Path.join(scratch_path, "orphan_save.ex"), "defmodule OrphanSave do\nend\n")

      scratch_uri =
        Document.Path.to_uri(Path.join([scratch_path, "orphan_save.ex"]))

      initial_text = "defmodule OrphanSave do\nend"

      # Open the file so it's in Document.Store
      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: scratch_uri,
                     languageId: "elixir",
                     version: 1,
                     text: initial_text
                   }
                 }
               })

      # This must not crash — same root cause as #549: nil project to active?/1
      assert :ok =
               notify(client, %{
                 method: "textDocument/didSave",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: scratch_uri}
                 }
               })

      # No engine calls should have been made
      refute_receive %{
                       "method" => "window/logMessage",
                       "params" => %{"type" => 1, "message" => "FunctionClauseError" <> _}
                     },
                     100

      refute_any_call(Expert.EngineApi.schedule_compile())
    end
  end

  describe "opening files without a project" do
    test "didOpen creates a bare project when file has no Mix project ancestor", %{
      client: client
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nil, id: 1, projects: nil, root_uri: nil)
               )

      assert_result(1, _)

      scratch_path = Path.join(System.tmp_dir!(), "expert_test_bare_#{System.unique_integer()}")
      File.mkdir_p!(scratch_path)
      File.write!(Path.join(scratch_path, "bare_file.ex"), "defmodule Bare do\nend\n")

      # Open a file in the scratch directory (no mix.exs anywhere above it)
      scratch_uri =
        Document.Path.to_uri(Path.join(scratch_path, "bare_file.ex"))

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: scratch_uri,
                     languageId: "elixir",
                     version: 1,
                     text: "defmodule Bare do\nend"
                   }
                 }
               })

      # Document should be stored
      assert_eventually(match?({:ok, _doc}, Document.Store.fetch(scratch_uri)))

      assert_eventually([project] = Expert.Project.Store.projects())
      assert project.kind == :bare

      expected_root_path = scratch_path |> Document.Path.to_uri() |> Document.Path.from_uri()

      assert Forge.Project.root_path(project) == expected_root_path
    end
  end

  describe "document-scoped requests for untracked files" do
    test "hover request for non-elixir file outside project does not crash", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())
      assert_request(client, "client/registerCapability", fn _params -> nil end)

      scratch_uri =
        Document.Path.to_uri(Path.join([project_root, "..", "scratch", "hover_target.txt"]))

      assert :ok =
               notify(client, %{
                 method: "textDocument/didOpen",
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{
                     uri: scratch_uri,
                     languageId: "plaintext",
                     version: 1,
                     text: "hover target"
                   }
                 }
               })

      assert_eventually(match?({:ok, _doc}, Document.Store.fetch(scratch_uri)))

      assert :ok =
               request(client, %{
                 method: "textDocument/hover",
                 id: 2,
                 jsonrpc: "2.0",
                 params: %{
                   textDocument: %{uri: scratch_uri},
                   position: %{line: 0, character: 0}
                 }
               })

      refute_receive %{
                       "method" => "window/logMessage",
                       "params" => %{"type" => 1, "message" => "FunctionClauseError" <> _}
                     },
                     100
    end
  end

  describe "dependency error handling" do
    test "prompts user with window/showMessageRequest on deps error", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)

      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn params ->
          assert params["type"] == 1
          assert params["message"] =~ "dependencies"
          assert length(params["actions"]) == 2

          %{"title" => "No"}
        end
      )
    end

    test "runs mix deps.get when user confirms", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        send(test_pid, :deps_fetched)
        :ok
      end)

      patch(Expert.Project.Supervisor, :stop_node, fn _project ->
        send(test_pid, :project_stopped)
        :ok
      end)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project, opts ->
        send(test_pid, {:project_restarted, opts})
        {:ok, self()}
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "Yes"} end
      )

      assert_receive :deps_fetched, 5000
      assert_receive :project_stopped, 5000
      assert_receive {:project_restarted, [blocked?: false]}, 5000
    end

    test "does not prompt again while deps fetch is already in progress", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        send(test_pid, {:deps_fetch_started, self()})

        receive do
          :continue_deps_fetch -> :ok
        after
          5000 -> {:error, :timeout}
        end
      end)

      patch(Expert.Project.Supervisor, :stop_node, fn _project ->
        send(test_pid, :project_stopped)
        :ok
      end)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project, opts ->
        send(test_pid, {:project_restarted, opts})
        {:ok, self()}
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "Yes"} end
      )

      assert_receive {:deps_fetch_started, fetch_pid}, 5000

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed again"}})

      refute_receive {:request, "window/showMessageRequest", _}, 1000

      send(fetch_pid, :continue_deps_fetch)

      assert_receive :project_stopped, 5000
      assert_receive {:project_restarted, [blocked?: false]}, 5000
    end

    test "does not run deps.get when user declines", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        send(test_pid, :unexpected_deps_fetch)
        :ok
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "No"} end
      )

      refute_receive :unexpected_deps_fetch, 1000
    end

    test "does not prompt again after user declines", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        send(test_pid, :unexpected_deps_fetch)
        :ok
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "no"} end
      )

      refute_receive :unexpected_deps_fetch, 1000

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed again"}})

      refute_receive {:request, "window/showMessageRequest", _}, 1000
      refute_receive :unexpected_deps_fetch, 1000
    end

    test "prompts to retry when mix deps.get fails", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        {:error, "Could not resolve dependency foo"}
      end)

      patch(Expert.Project.Supervisor, :stop_node, fn _project ->
        send(test_pid, :unexpected_project_stopped)
        :ok
      end)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project ->
        {:ok, self()}
      end)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project, _opts ->
        send(test_pid, :unexpected_project_restarted)
        {:ok, self()}
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "Yes"} end
      )

      assert_request(
        client,
        "window/showMessageRequest",
        fn params ->
          assert params["message"] =~ "mix deps.get failed"
          assert params["message"] =~ "retry"
          assert Enum.map(params["actions"], & &1["title"]) == ["Retry", "Cancel"]

          %{"title" => "Cancel"}
        end
      )

      refute_receive :unexpected_project_stopped, 1000
      refute_receive :unexpected_project_restarted, 1000
    end

    test "reruns mix deps.get when user retries after a fetch failure", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      test_pid = self()
      attempt_counter = :counters.new(1, [])

      patch(Expert.EngineApi, :clean_and_fetch_deps, fn _project ->
        :counters.add(attempt_counter, 1, 1)

        case :counters.get(attempt_counter, 1) do
          1 ->
            send(test_pid, :deps_fetch_failed)
            {:error, "Could not resolve dependency foo"}

          2 ->
            send(test_pid, :deps_fetch_succeeded)
            :ok
        end
      end)

      patch(Expert.Project.Supervisor, :stop_node, fn _project ->
        send(test_pid, :project_stopped)
        :ok
      end)

      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project, opts ->
        send(test_pid, {:project_restarted, opts})
        {:ok, self()}
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())

      assert_request(client, "client/registerCapability", fn _params -> nil end)
      Expert.Configuration.set(%{Expert.Configuration.get() | auto_fetch_dependencies: false})

      send(server.lsp, {:deps_error, main_project, %{last_message: "deps failed"}})

      assert_request(
        client,
        "window/showMessageRequest",
        fn _params -> %{"title" => "Yes"} end
      )

      assert_request(
        client,
        "window/showMessageRequest",
        fn params ->
          assert params["message"] =~ "Would you like to retry?"
          %{"title" => "Retry"}
        end
      )

      assert_receive :deps_fetch_failed, 5000
      assert_receive :deps_fetch_succeeded, 5000
      assert_receive :project_stopped, 5000
      assert_receive {:project_restarted, [blocked?: false]}, 5000
    end
  end

  describe "bootstrap error handling" do
    test "sends a single window/showMessage with the bootstrap error message", %{
      client: client,
      server: server,
      project_root: project_root,
      main_project: main_project
    } do
      patch(Expert.Project.Supervisor, :ensure_node_started, fn _project ->
        {:ok, nil}
      end)

      assert :ok =
               request(client, initialize_request(project_root, id: 1, projects: [main_project]))

      assert_result(1, _)
      assert :ok = notify(client, initialized_notification())
      assert_request(client, "client/registerCapability", fn _params -> nil end)

      # Simulate what happens when Node.init returns
      # {:stop, {:shutdown, {:bootstrap_error, message}}}
      # OTP wraps it as {:shutdown, {:failed_to_start_child, {Expert.Project.Node, name},
      #   {:shutdown, {:bootstrap_error, message}}}}
      project_name = Forge.Project.name(main_project)
      error_message = "Project directory has insufficient permissions"

      bootstrap_reason =
        {:shutdown,
         {:failed_to_start_child, {Expert.Project.Node, project_name},
          {:shutdown, {:bootstrap_error, error_message}}}}

      send(server.lsp, {:engine_initialized, main_project, {:error, bootstrap_reason}})

      assert_notification(
        "window/showMessage",
        %{"type" => 1, "message" => message}
      )

      assert message =~ error_message
    end
  end
end
