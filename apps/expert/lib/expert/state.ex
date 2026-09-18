defmodule Expert.State do
  import Forge.EngineApi.Messages

  alias Expert.CodeIntelligence
  alias Expert.Configuration
  alias Expert.Document.Context
  alias Expert.Document.Lookup
  alias Expert.EngineApi
  alias Expert.Project
  alias Expert.Project.Store
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Enumerations
  alias GenLSP.Notifications
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  defstruct initialized?: false,
            shutdown_received?: false,
            in_flight_requests: %{},
            deps_declined_projects: MapSet.new()

  @supported_code_actions [
    Enumerations.CodeActionKind.quick_fix(),
    Enumerations.CodeActionKind.refactor(),
    Enumerations.CodeActionKind.refactor_extract(),
    Enumerations.CodeActionKind.refactor_inline(),
    Enumerations.CodeActionKind.refactor_rewrite(),
    Enumerations.CodeActionKind.source(),
    Enumerations.CodeActionKind.source_fix_all(),
    Enumerations.CodeActionKind.source_organize_imports()
  ]

  def new do
    %__MODULE__{}
  end

  def initialize(
        %__MODULE__{initialized?: false} = state,
        %Requests.Initialize{
          params: %Structures.InitializeParams{} = event
        }
      ) do
    client_name =
      case event.client_info do
        %{name: name} -> name
        _ -> nil
      end

    normalized_folders = normalize_workspace_folders(event)

    folder_paths =
      Enum.map(normalized_folders, fn %Structures.WorkspaceFolder{uri: uri} ->
        Forge.Workspace.folder_path_from_uri(uri)
      end)

    folder_paths
    |> Forge.Workspace.new()
    |> Forge.Workspace.set_workspace()

    event.capabilities
    |> Configuration.new(client_name)
    |> Configuration.set()

    new_state = %__MODULE__{state | initialized?: true}

    response = initialize_result()

    {:ok, response, new_state}
  end

  def initialize(%__MODULE__{initialized?: true}, %Requests.Initialize{}) do
    {:error, :already_initialized}
  end

  def apply(%__MODULE__{initialized?: false}, request) do
    Logger.error("Received #{request.method} before server was initialized")
    {:error, :not_initialized}
  end

  def apply(%__MODULE__{shutdown_received?: true} = state, %Notifications.Exit{}) do
    Logger.warning("Received an Exit notification. Halting the server in 150ms")
    :timer.apply_after(50, System, :halt, [0])
    {:ok, state}
  end

  def apply(%__MODULE__{shutdown_received?: true}, request) do
    Logger.error("Received #{request.method} after shutdown. Ignoring")
    {:error, :shutting_down}
  end

  def apply(%__MODULE__{} = state, %Notifications.WorkspaceDidChangeConfiguration{} = event) do
    old_config = Configuration.get()

    case Configuration.on_change(event) do
      {:ok, config} ->
        apply_configuration_side_effects(old_config, config)

        {:ok, state}

      {:ok, config, request} ->
        apply_configuration_side_effects(old_config, config)

        GenLSP.request(Expert.get_lsp(), request)
        {:ok, state}
    end
  end

  def apply(
        %__MODULE__{} = state,
        %Notifications.WorkspaceDidChangeWorkspaceFolders{
          params: %Structures.DidChangeWorkspaceFoldersParams{
            event: %Structures.WorkspaceFoldersChangeEvent{added: added, removed: removed}
          }
        }
      ) do
    added_paths = Enum.map(added, fn %{uri: uri} -> Forge.Workspace.folder_path_from_uri(uri) end)

    removed_paths =
      Enum.map(removed, fn %{uri: uri} -> Forge.Workspace.folder_path_from_uri(uri) end)

    workspace = Forge.Workspace.get_workspace() || Forge.Workspace.new([])

    workspace
    |> Forge.Workspace.add_folders(added_paths)
    |> Forge.Workspace.remove_folders(removed_paths)
    |> Forge.Workspace.set_workspace()

    added_projects =
      added
      |> Lookup.projects_for_folders()
      |> Enum.map(fn project -> Store.find_by_root_uri(project.root_uri) || project end)

    remaining_workspace_paths =
      case Forge.Workspace.get_workspace() do
        %Forge.Workspace{workspace_folders: workspace_folders} -> workspace_folders
        _ -> []
      end

    remaining_root_uris =
      Lookup.project_root_uris_for_paths(remaining_workspace_paths)

    removed_root_uris = Lookup.project_root_uris_for_paths(removed_paths)

    removed_projects =
      Store.projects()
      |> Enum.filter(fn project ->
        removed_from_workspace?(project, removed_paths, removed_root_uris) and
          not in_workspace?(project, remaining_workspace_paths, remaining_root_uris)
      end)

    for project <- removed_projects do
      Expert.Project.Supervisor.stop_node(project)
    end

    Store.add_projects(added_projects)
    Store.remove_projects(removed_projects)

    for project <- added_projects do
      Task.Supervisor.start_child(:expert_task_queue, fn ->
        Expert.Project.Supervisor.ensure_node_started(project)
      end)
    end

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidChange{params: params}) do
    uri = params.text_document.uri
    version = params.text_document.version
    context = Lookup.resolve(uri, Store.projects())

    case Document.Store.get_and_update(
           uri,
           &Document.apply_content_changes(&1, version, params.content_changes)
         ) do
      {:ok, updated_source} ->
        if Store.ready?(context.project) do
          updated_message =
            file_changed(
              uri: updated_source.uri,
              open?: true,
              from_version: version,
              to_version: updated_source.version
            )

          EngineApi.broadcast(context.project, updated_message)

          if Configuration.compile_on_type?() do
            EngineApi.compile_document(context.project, updated_source)
          end
        end

        {:ok, state}

      error ->
        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidOpen{} = did_open) do
    %GenLSP.Structures.TextDocumentItem{
      text: text,
      uri: uri,
      version: version,
      language_id: language_id
    } = did_open.params.text_document

    start_project_for_uri(uri)

    case Document.Store.open(uri, text, version, language_id) do
      :ok ->
        Logger.info("Opened #{uri}")

        {:ok, state}

      error ->
        Logger.error("Could not open #{uri} #{inspect(error)}")

        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidClose{params: params}) do
    uri = params.text_document.uri

    case Document.Store.close(uri) do
      :ok ->
        {:ok, state}

      error ->
        Logger.warning(
          "Received textDocument/didClose for a file that wasn't open. URI was #{uri}"
        )

        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidSave{params: params}) do
    uri = params.text_document.uri
    context = Lookup.resolve(uri, Store.projects())

    case Document.Store.save(uri) do
      :ok ->
        case context do
          %Context{project: %Project{kind: :mix} = project} ->
            if Store.ready?(project) do
              EngineApi.schedule_compile(project, false)
            end

          %Context{project: %Project{kind: :bare}} ->
            :ok
        end

        {:ok, state}

      error ->
        Logger.error("Save failed for uri #{uri} error was #{inspect(error)}")
        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Requests.Shutdown{}) do
    Logger.info("Shutting down")

    {:ok, nil, %__MODULE__{state | shutdown_received?: true}}
  end

  def apply(%__MODULE__{} = state, %Notifications.WorkspaceDidChangeWatchedFiles{params: params}) do
    for project <- Store.projects(),
        change <- params.changes do
      params = filesystem_event(project: project, uri: change.uri, event_type: change.type)

      if Store.ready?(project) do
        EngineApi.broadcast(project, params)
      end
    end

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, msg) do
    Logger.error("Ignoring unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  def deps_declined?(%__MODULE__{deps_declined_projects: declined}, %Project{} = project) do
    MapSet.member?(declined, project.root_uri)
  end

  def mark_deps_declined(
        %__MODULE__{deps_declined_projects: declined} = state,
        %Project{} = project
      ) do
    %__MODULE__{state | deps_declined_projects: MapSet.put(declined, project.root_uri)}
  end

  @doc """
  Resolves and applies the Elixir source path for a single project that has just
  become ready.
  """
  def propagate_elixir_source_path_for(%Project{} = project) do
    if Store.ready?(project) do
      apply_elixir_source_path(project, Configuration.get())
    end

    :ok
  rescue
    _ -> :ok
  end

  defp propagate_elixir_source_path(%Configuration{} = config) do
    for project <- Store.projects(), Store.ready?(project) do
      apply_elixir_source_path(project, config)
    end
  rescue
    _ -> :ok
  end

  defp apply_elixir_source_path(%Project{} = project, %Configuration{} = config) do
    source_path =
      case config.elixir_source_path do
        nil ->
          EngineApi.call(project, Engine.CodeIntelligence.ElixirSource, :detect, [])

        path ->
          path
      end

    case source_path do
      nil ->
        EngineApi.call(project, Application, :delete_env, [:language_server, :elixir_src])

      elixir_source_path ->
        EngineApi.call(project, Application, :put_env, [
          :language_server,
          :elixir_src,
          elixir_source_path
        ])
    end
  end

  defp apply_configuration_side_effects(%Configuration{} = old_config, %Configuration{} = config) do
    if config.elixir_source_path != old_config.elixir_source_path do
      propagate_elixir_source_path(config)
    end

    if runtime_executable_paths_changed?(old_config, config) do
      restart_runtime_projects()
    end
  end

  defp runtime_executable_paths_changed?(%Configuration{} = old_config, %Configuration{} = config) do
    config.elixir_executable_path != old_config.elixir_executable_path or
      config.erlang_executable_path != old_config.erlang_executable_path
  end

  defp restart_runtime_projects do
    for project <- Store.projects(), not Store.blocked?(project) do
      restart_runtime_project(project)
    end

    :ok
  end

  defp restart_runtime_project(%Project{} = project) do
    case Task.Supervisor.start_child(:expert_task_queue, fn ->
           Expert.Project.Supervisor.restart_node(project, blocked?: false)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to schedule project restart for #{Project.name(project)}: #{inspect(reason)}"
        )
    end
  end

  def initialize_result do
    sync_options =
      %GenLSP.Structures.TextDocumentSyncOptions{
        open_close: true,
        change: GenLSP.Enumerations.TextDocumentSyncKind.incremental(),
        save: true
      }

    code_action_options =
      %GenLSP.Structures.CodeActionOptions{
        code_action_kinds: @supported_code_actions,
        resolve_provider: Configuration.client_resolves_code_action_edits?()
      }

    code_lens_options =
      %GenLSP.Structures.CodeLensOptions{resolve_provider: false}

    command_options =
      %GenLSP.Structures.ExecuteCommandOptions{commands: Handlers.Commands.names()}

    completion_options =
      %GenLSP.Structures.CompletionOptions{
        trigger_characters: CodeIntelligence.Completion.trigger_characters()
      }

    server_capabilities =
      %Structures.ServerCapabilities{
        code_action_provider: code_action_options,
        code_lens_provider: code_lens_options,
        completion_provider: completion_options,
        definition_provider: true,
        document_formatting_provider: true,
        document_symbol_provider: true,
        execute_command_provider: command_options,
        folding_range_provider: true,
        hover_provider: true,
        references_provider: true,
        signature_help_provider: %Structures.SignatureHelpOptions{
          trigger_characters: Handlers.SignatureHelp.trigger_characters()
        },
        text_document_sync: sync_options,
        workspace_symbol_provider: true,
        workspace: %{
          workspace_folders: %Structures.WorkspaceFoldersServerCapabilities{
            supported: true,
            change_notifications: true
          }
        }
      }

    %GenLSP.Structures.InitializeResult{
      capabilities: server_capabilities,
      server_info: %{
        name: "Expert",
        version: Expert.vsn()
      }
    }
  end

  defp start_project_for_uri(uri) do
    project = Lookup.discover_project(uri)

    if !(Store.blocked?(project) or Store.find_by_root_uri(project.root_uri) != nil) do
      Store.add_projects([project])

      Task.Supervisor.start_child(:expert_task_queue, fn ->
        Expert.Project.Supervisor.ensure_node_started(project)
      end)
    end

    :ok
  end

  defp removed_from_workspace?(%Project{} = project, removed_paths, removed_root_uris) do
    MapSet.member?(removed_root_uris, project.root_uri) or
      Enum.any?(removed_paths, &project_in_folder?(&1, project))
  end

  defp in_workspace?(%Project{} = project, workspace_paths, workspace_root_uris) do
    MapSet.member?(workspace_root_uris, project.root_uri) or
      Enum.any?(workspace_paths, &project_in_folder?(&1, project))
  end

  defp project_in_folder?(folder_path, %Project{} = project) do
    folder_path = Path.expand(folder_path)
    project_root_path = Project.root_path(project)

    is_binary(project_root_path) and Forge.Path.parent_path?(project_root_path, folder_path)
  end

  @spec normalize_workspace_folders(GenLSP.Structures.InitializeParams.t()) ::
          [Structures.WorkspaceFolder.t()]
  def normalize_workspace_folders(%GenLSP.Structures.InitializeParams{} = event) do
    cond do
      is_list(event.workspace_folders) and event.workspace_folders != [] ->
        event.workspace_folders

      is_binary(event.root_uri) and event.root_uri != "" ->
        path = Forge.Workspace.folder_path_from_uri(event.root_uri)
        [%Structures.WorkspaceFolder{uri: event.root_uri, name: Path.basename(path)}]

      true ->
        []
    end
  end
end
