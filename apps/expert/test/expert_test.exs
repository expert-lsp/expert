defmodule Expert.ExpertTest do
  use ExUnit.Case, async: false
  use Patch

  import Expert.Test.Protocol.TransportSupport
  import ExUnit.CaptureLog

  alias Expert.Document.Context
  alias Expert.State
  alias Forge.CodeAction
  alias Forge.Document
  alias Forge.Project
  alias Forge.Test.Fixtures
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Structures.DidChangeConfigurationParams

  setup do
    :persistent_term.erase(Expert.Configuration)
    Forge.Workspace.set_workspace(nil)
    with_patched_transport()

    # These tests call `Expert.handle_info/2` directly (bypassing `Expert.Application`),
    # so we must start the stores that runtime boot normally provides.
    start_supervised!({Forge.Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!({Task.Supervisor, name: :expert_task_queue})
    start_supervised!({Expert.Project.Store, []})

    # window/logMessage comes from Logger via WindowLogHandler,
    # so tests that assert on log notifications must allow :info events through.
    # The :default console handler is suppressed to avoid polluting test output.
    Expert.Logging.WindowLogHandler.attach()
    Logger.configure(level: :info)
    :logger.update_handler_config(:default, :level, :none)

    on_exit(fn ->
      :persistent_term.erase(Expert.Configuration)
      Forge.Workspace.set_workspace(nil)
      Logger.configure(level: :none)
      :logger.update_handler_config(:default, :level, :all)
    end)

    :ok
  end

  test "sends an error message on engine initialization error" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    reason = :something_bad

    assert {:noreply, ^lsp} =
             Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

    error_message = "[#{Project.name(project)}] Failed to initialize: #{inspect(reason)}"
    error_message_type = GenLSP.Enumerations.MessageType.error()

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowLogMessage{
                      params: %GenLSP.Structures.LogMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowShowMessage{
                      params: %GenLSP.Structures.ShowMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}
  end

  describe "engine build failure messages" do
    test "include captured build output" do
      project = Fixtures.project()
      lsp = initialize_lsp(project)

      output = """
      ** (Mix.Error) httpc request failed with: {:failed_connect, ...}.

      Could not install Rebar because Mix could not download metadata at https://builds.hex.pm/installs/rebar.csv.

          (mix  1.17.3) lib/mix.ex:647: Mix.raise/2
          .../priv/build_engine.exs:31: (file)\
      """

      reason =
        {:shutdown,
         {:failed_to_start_child, {Expert.Project.Node, "demo::1"},
          {:error, "Build script exited with status: 1", output}}}

      assert {:noreply, ^lsp} =
               Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

      assert_receive {:transport,
                      %GenLSP.Notifications.WindowShowMessage{
                        params: %GenLSP.Structures.ShowMessageParams{message: message}
                      }}

      assert message =~ "Engine build failed for demo::1"
      assert message =~ "Build script exited with status: 1"
      # The actual error must be visible to the user, not just the script frame.
      assert message =~ "** (Mix.Error) httpc request failed with"
      assert message =~ "Could not install Rebar because Mix could not download metadata"
    end

    test "omit the details block when captured output is empty" do
      project = Fixtures.project()
      lsp = initialize_lsp(project)

      reason =
        {:shutdown,
         {:failed_to_start_child, {Expert.Project.Node, "demo::1"},
          {:error, "Build script exited with status: 1", ""}}}

      assert {:noreply, ^lsp} =
               Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

      assert_receive {:transport,
                      %GenLSP.Notifications.WindowShowMessage{
                        params: %GenLSP.Structures.ShowMessageParams{message: message}
                      }}

      assert message =~ "Engine build failed for demo::1"
      assert message =~ "Build script exited with status: 1"
      # No trailing newlines / empty section when there is nothing to show.
      refute String.ends_with?(message, "\n\n")
    end
  end

  test "logs error when Task.Supervisor.start_child fails during initialization" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    patch(Expert.Project.Store, :projects, [project])
    patch(Task.Supervisor, :start_child, fn _sup, _fun -> {:error, :max_children} end)

    Logger.configure(level: :error)

    log =
      capture_log(fn ->
        assert {:noreply, ^lsp} =
                 Expert.handle_notification(%GenLSP.Notifications.Initialized{}, lsp)
      end)

    Logger.configure(level: :none)

    assert log =~ "Failed to start project initialization for"
    assert log =~ "max_children"
  end

  test "suppresses window/logMessage for emacs client" do
    project = Fixtures.project()
    lsp = initialize_lsp(project, client_name: "Emacs")
    reason = :something_bad

    assert {:noreply, ^lsp} =
             Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

    error_message = "[#{Project.name(project)}] Failed to initialize: #{inspect(reason)}"
    error_message_type = GenLSP.Enumerations.MessageType.error()

    refute_receive {:transport, %GenLSP.Notifications.WindowLogMessage{}}

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowShowMessage{
                      params: %GenLSP.Structures.ShowMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}
  end

  test "accepts didChangeConfiguration notifications with null settings" do
    project = Fixtures.project()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))

    notification = %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{settings: nil}
    }

    assert {:ok, ^state} = State.apply(state, notification)

    config = Expert.Configuration.get()
    assert config.log_level == :info
    assert config.workspace_symbols.min_query_length == 2
  end

  test "loads enableCompilation from initialization options" do
    project = Fixtures.project()

    {:ok, _response, _state} =
      State.initialize(
        State.new(),
        initialize_request(project, initialization_options: %{"enableCompilation" => false})
      )

    refute Expert.Configuration.compilation_enabled?()
  end

  test "ignores non-map initialization options" do
    project = Fixtures.project()

    assert {:ok, _response, _state} =
             State.initialize(
               State.new(),
               initialize_request(project, initialization_options: [])
             )

    assert Expert.Configuration.compilation_enabled?()
  end

  test "stops project Engines when enableCompilation is disabled" do
    project = Fixtures.project()
    test_pid = self()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))
    Expert.Project.Store.add_projects([project])

    uri = project |> Fixtures.file_path("lib/open.ex") |> Document.Path.to_uri()
    assert :ok = Document.Store.open(uri, "defmodule Open do", 1)

    patch(Expert.Project.Supervisor, :stop_engine, fn stopped_project ->
      send(test_pid, {:stopping_engine, stopped_project.root_uri, self()})

      receive do
        :stopped -> :ok
      end
    end)

    notification = %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{settings: %{"enableCompilation" => false}}
    }

    request = Task.async(fn -> State.apply(state, notification) end)
    assert_receive {:stopping_engine, root_uri, engine_task}
    refute Task.yield(request, 50)

    send(engine_task, :stopped)
    assert {:ok, ^state} = Task.await(request)
    refute Expert.Configuration.compilation_enabled?()
    assert root_uri == project.root_uri

    assert_receive {:transport,
                    %GenLSP.Notifications.TextDocumentPublishDiagnostics{
                      params: %GenLSP.Structures.PublishDiagnosticsParams{
                        uri: ^uri,
                        diagnostics: [_diagnostic]
                      }
                    }}
  end

  test "a failed dependency fetch does not keep disabled compilation blocked" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)
    test_pid = self()

    Expert.Project.Store.add_projects([project])
    Expert.Project.Store.transition(project, :blocked)
    {:ok, _config} = Expert.Configuration.on_change(%{"enableCompilation" => false})

    assert {:noreply, ^lsp} =
             Expert.handle_info({:deps_fetch_failed, project, "fetch failed"}, lsp)

    refute Expert.Project.Store.blocked?(project)

    patch(Expert.Project.Supervisor, :start_engine, fn ^project ->
      send(test_pid, :engine_enabled)
      :ok
    end)

    {:ok, _config} = Expert.Configuration.on_change(%{"enableCompilation" => true})
    assert :ok = Expert.Project.Supervisor.start_engine(project)
    assert_receive :engine_enabled
  end

  test "routes watched index file changes to the local indexer while compilation is disabled" do
    project = Fixtures.project()
    other_project = Fixtures.project(:umbrella)
    test_pid = self()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))
    Expert.Project.Store.add_projects([project, other_project])
    {:ok, _config} = Expert.Configuration.on_change(%{"enableCompilation" => false})

    patch(Expert.Project.Indexer, :refresh, fn refreshed_project ->
      send(test_pid, {:index_refreshed, refreshed_project.root_uri})
      :ok
    end)

    notification = %GenLSP.Notifications.WorkspaceDidChangeWatchedFiles{
      params: %GenLSP.Structures.DidChangeWatchedFilesParams{
        changes: [
          %GenLSP.Structures.FileEvent{
            uri:
              project
              |> Fixtures.file_path("_build/test/lib/app/ebin/App.beam")
              |> Document.Path.to_uri(),
            type: GenLSP.Enumerations.FileChangeType.changed()
          },
          %GenLSP.Structures.FileEvent{
            uri:
              project
              |> Fixtures.file_path("lib/app.ex")
              |> Document.Path.to_uri(),
            type: GenLSP.Enumerations.FileChangeType.deleted()
          },
          %GenLSP.Structures.FileEvent{
            uri:
              project
              |> Fixtures.file_path("mix.lock")
              |> Document.Path.to_uri(),
            type: GenLSP.Enumerations.FileChangeType.changed()
          }
        ]
      }
    }

    assert {:ok, ^state} = State.apply(state, notification)
    assert_receive {:index_refreshed, root_uri}
    assert root_uri == project.root_uri
    refute_receive {:index_refreshed, _root_uri}
  end

  test "restarts pending projects when runtime executable configuration changes" do
    project = Fixtures.project()
    test_pid = self()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))

    Expert.Project.Store.add_projects([project])

    patch(Expert.Project.Supervisor, :restart_node, fn restarted_project, opts ->
      send(test_pid, {:project_restarted, restarted_project.root_uri, opts})
      {:ok, self()}
    end)

    notification = %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{
        settings: %{"elixirExecutablePath" => "/opt/elixir/bin/elixir"}
      }
    }

    assert {:ok, ^state} = State.apply(state, notification)

    assert_receive {:project_restarted, root_uri, [blocked?: false]}
    assert root_uri == project.root_uri
  end

  test "does not restart blocked projects when runtime executable configuration changes" do
    project = Fixtures.project()
    test_pid = self()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))

    Expert.Project.Store.add_projects([project])
    Expert.Project.Store.transition(project, :blocked)

    patch(Expert.Project.Supervisor, :restart_node, fn restarted_project, opts ->
      send(test_pid, {:project_restarted, restarted_project.root_uri, opts})
      {:ok, self()}
    end)

    notification = %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{
        settings: %{"elixirExecutablePath" => "/opt/elixir/bin/elixir"}
      }
    }

    assert {:ok, ^state} = State.apply(state, notification)

    refute_receive {:project_restarted, _root_uri, _opts}
  end

  test "initialization stores an empty workspace when root_uri and workspace_folders are nil" do
    request = %GenLSP.Requests.Initialize{
      id: 1,
      jsonrpc: "2.0",
      method: "initialize",
      params: %GenLSP.Structures.InitializeParams{
        capabilities: %GenLSP.Structures.ClientCapabilities{},
        client_info: nil,
        process_id: "",
        root_uri: nil,
        root_path: nil,
        workspace_folders: nil
      }
    }

    assert {:ok, _response, _state} = State.initialize(State.new(), request)

    assert %Forge.Workspace{workspace_folders: []} =
             Forge.Workspace.get_workspace()
  end

  test "foldingRange request is served before the engine is initialized" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    # Project is known but not yet ready
    Expert.Project.Store.add_projects([project])

    uri = Fixtures.file_uri(project, "lib/foo.ex")
    document = Document.new(uri, "defmodule Foo do\n  :ok\nend\n", 1)

    patch(Expert.Document.Lookup, :resolve_from_request, fn _request, _projects ->
      {:ok, Context.new(uri, document, project)}
    end)

    request = %GenLSP.Requests.TextDocumentFoldingRange{
      id: 1,
      jsonrpc: "2.0",
      method: "textDocument/foldingRange",
      params: %GenLSP.Structures.FoldingRangeParams{
        text_document: %GenLSP.Structures.TextDocumentIdentifier{uri: uri}
      }
    }

    assert {:reply, [_ | _], ^lsp} = Expert.handle_request(request, lsp)
  end

  test "document requests return an error when the document cannot be loaded" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    Expert.Project.Store.add_projects([project])
    patch(Expert.Project.EngineRuntime, :available?, fn _project -> true end)

    request = %GenLSP.Requests.TextDocumentHover{
      id: 1,
      jsonrpc: "2.0",
      method: "textDocument/hover",
      params: %GenLSP.Structures.HoverParams{
        text_document: %GenLSP.Structures.TextDocumentIdentifier{
          uri:
            project
            |> Forge.Project.root_path()
            |> Path.join("lib/not_open.ex")
            |> Forge.Document.Path.to_uri()
        },
        position: %GenLSP.Structures.Position{line: 0, character: 0}
      }
    }

    assert {
             :reply,
             %GenLSP.ErrorResponse{
               code: code,
               message: "Document could not be loaded"
             },
             ^lsp
           } = Expert.handle_request(request, lsp)

    assert code == GenLSP.Enumerations.ErrorCodes.invalid_request()
  end

  test "codeAction/resolve for a foreign action is echoed back, not routed as a document request" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    Expert.Project.Store.add_projects([project])

    # A code action from some other provider, carrying a uri for a document that
    # is not open. It must not be treated as a document request (which would fail
    # with "Document could not be loaded"); the resolve handler echoes it back.
    uri =
      project
      |> Forge.Project.root_path()
      |> Path.join("lib/not_open.ex")
      |> Forge.Document.Path.to_uri()

    action = %GenLSP.Structures.CodeAction{
      title: "Some other action",
      data: %{"provider" => "something-else", "uri" => uri}
    }

    request = %GenLSP.Requests.CodeActionResolve{
      id: 1,
      jsonrpc: "2.0",
      method: "codeAction/resolve",
      params: action
    }

    assert {:reply, %GenLSP.Structures.CodeAction{title: "Some other action"}, ^lsp} =
             Expert.handle_request(request, lsp)
  end

  test "document request conversion uses the resolved context document as fallback" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)
    test_pid = self()

    Expert.Project.Store.add_projects([project])
    patch(Expert.Project.EngineRuntime, :available?, fn _project -> true end)

    uri = Document.Path.to_uri(Path.join(Forge.Project.root_path(project), "lib/context.ex"))

    document =
      Document.new(
        uri,
        """
        defmodule Context do
          alias Foo.Bar
        end
        """,
        1,
        "elixir"
      )

    range = %GenLSP.Structures.Range{
      start: %GenLSP.Structures.Position{line: 1, character: 2},
      end: %GenLSP.Structures.Position{line: 1, character: 15}
    }

    request = %GenLSP.Requests.TextDocumentCodeAction{
      id: 1,
      jsonrpc: "2.0",
      method: "textDocument/codeAction",
      params: %GenLSP.Structures.CodeActionParams{
        text_document: %GenLSP.Structures.TextDocumentIdentifier{uri: uri},
        range: range,
        context: %GenLSP.Structures.CodeActionContext{
          diagnostics: [
            %GenLSP.Structures.Diagnostic{
              range: range,
              message: "Test diagnostic",
              source: "TestSource"
            }
          ],
          only: nil,
          trigger_kind: 1
        }
      }
    }

    refute Document.Store.open?(uri)

    patch(Expert.Document.Lookup, :resolve_from_request, fn _request, _projects ->
      {:ok, Context.new(uri, document, project)}
    end)

    patch(Expert.EngineApi, :code_actions, fn
      ^project,
      ^document,
      %Document.Range{} = native_range,
      [%CodeAction.Diagnostic{range: %Document.Range{}}] = diagnostics,
      :all,
      1,
      _opts ->
        send(test_pid, {:code_actions, native_range, diagnostics})
        []
    end)

    assert {:reply, [], ^lsp} = Expert.handle_request(request, lsp)

    assert_receive {:code_actions, %Document.Range{}, [%CodeAction.Diagnostic{}]}
  end

  defp initialize_lsp(project, opts \\ []) do
    assigns = start_supervised!(GenLSP.Assigns, id: make_ref())

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, opts))
    GenLSP.Assigns.merge(assigns, %{state: state})

    lsp = %GenLSP.LSP{mod: Expert, assigns: assigns}
    # These tests do not boot Expert.Application, so we mirror runtime setup by
    # setting the global LSP reference used by the window logger handler.
    :persistent_term.put(:expert_lsp, lsp)
    lsp
  end

  defp initialize_request(project, opts) do
    root_uri = project.root_uri
    root_path = Forge.Project.root_path(project)
    client_name = opts[:client_name]

    client_info =
      if is_binary(client_name) do
        %{name: client_name, version: "test"}
      end

    %GenLSP.Requests.Initialize{
      id: 1,
      jsonrpc: "2.0",
      method: "initialize",
      params: %GenLSP.Structures.InitializeParams{
        capabilities: %GenLSP.Structures.ClientCapabilities{},
        client_info: client_info,
        process_id: "",
        root_uri: root_uri,
        root_path: root_path,
        initialization_options: opts[:initialization_options],
        workspace_folders: [
          %GenLSP.Structures.WorkspaceFolder{
            name: root_path,
            uri: root_uri
          }
        ]
      }
    }
  end
end
