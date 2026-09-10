defmodule Expert do
  use GenLSP

  alias Expert.Document.Lookup
  alias Expert.Project.Store
  alias Expert.Protocol.Convert
  alias Expert.Protocol.Id
  alias Expert.Provider.Handler
  alias Expert.Provider.Handlers
  alias Expert.State
  alias Forge.Project
  alias GenLSP.Enumerations
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @server_specific_messages [
    GenLSP.Notifications.TextDocumentDidChange,
    GenLSP.Notifications.WorkspaceDidChangeConfiguration,
    GenLSP.Notifications.WorkspaceDidChangeWatchedFiles,
    GenLSP.Notifications.WorkspaceDidChangeWorkspaceFolders,
    GenLSP.Notifications.TextDocumentDidClose,
    GenLSP.Notifications.TextDocumentDidOpen,
    GenLSP.Notifications.TextDocumentDidSave,
    GenLSP.Notifications.Exit,
    GenLSP.Requests.Shutdown
  ]
  @dialyzer {:nowarn_function, apply_to_state: 2}

  def vsn, do: :expert |> Application.spec(:vsn) |> to_string()

  def get_lsp, do: :persistent_term.get(:expert_lsp, nil)

  def terminate(message, status \\ 0) do
    Logger.error(message)
    System.stop(status)
  end

  def start_link(args) do
    Logger.debug(inspect(args))

    GenLSP.start_link(
      __MODULE__,
      [],
      Keyword.take(args, [:buffer, :assigns, :task_supervisor, :name])
    )
  end

  def init(lsp, _args) do
    :persistent_term.put(:expert_lsp, lsp)
    {:ok, assign(lsp, state: State.new())}
  end

  def handle_request(%GenLSP.Requests.Initialize{} = request, lsp) do
    state = assigns(lsp).state

    with {:ok, response, state} <- State.initialize(state, request),
         {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
      normalized_folders = State.normalize_workspace_folders(request.params)
      projects = Lookup.projects_for_folders(normalized_folders)

      Store.set_projects(projects)

      {:reply, response, assign(lsp, state: state)}
    else
      {:error, :already_initialized} ->
        response = %GenLSP.ErrorResponse{
          code: GenLSP.Enumerations.ErrorCodes.invalid_request(),
          message: "Already initialized"
        }

        {:reply, response, lsp}

      {:error, reason} ->
        response = %GenLSP.ErrorResponse{
          code: GenLSP.Enumerations.ErrorCodes.server_not_initialized(),
          message: "Failed to initialize: #{inspect(reason)}"
        }

        {:reply, response, lsp}
    end
  end

  def handle_request(%mod{} = request, lsp) when mod in @server_specific_messages do
    Logger.error("handling server specific request #{Macro.to_string(mod)}")

    with {:ok, request} <- Expert.Protocol.Convert.to_native(request),
         {:ok, response, state} <- apply_to_state(assigns(lsp).state, request),
         {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
      {:reply, response, assign(lsp, state: state)}
    else
      error ->
        message = "Failed to handle #{mod}, #{inspect(error)}"
        Logger.error(message)

        {:reply,
         %GenLSP.ErrorResponse{
           code: GenLSP.Enumerations.ErrorCodes.internal_error(),
           message: message
         }, lsp}
    end
  end

  def handle_request(request, lsp) do
    with {:ok, handler} <- fetch_handler(request),
         {:ok, context} <- check_engine_initialized(request, handler),
         {:ok, request} <- Convert.to_native(request, context_document(context)),
         {:ok, response} <- handler.handle(request, context),
         {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
      {:reply, response, lsp}
    else
      {:error, {:unhandled, _}} ->
        Logger.info("Unhandled request: #{request.method}")

        {:reply,
         %GenLSP.ErrorResponse{
           code: GenLSP.Enumerations.ErrorCodes.method_not_found(),
           message: "Method not found"
         }, lsp}

      {:error, :engine_not_initialized, project} ->
        Logger.info(
          "Received request #{request.method} before engine for #{project && Project.name(project)} was initialized. Ignoring."
        )

        {:reply, nil, lsp}

      {:error, :document_not_found} ->
        Logger.info("Received request #{request.method} for a document that could not be loaded.")

        {:reply,
         %GenLSP.ErrorResponse{
           code: GenLSP.Enumerations.ErrorCodes.invalid_request(),
           message: "Document could not be loaded"
         }, lsp}

      error ->
        message = "Failed to handle #{request.method}, #{inspect(error)}"
        Logger.error(message)

        {:reply,
         %GenLSP.ErrorResponse{
           code: GenLSP.Enumerations.ErrorCodes.internal_error(),
           message: message
         }, lsp}
    end
  end

  defp context_document(%{document: %Forge.Document{} = document}), do: document
  defp context_document(_), do: nil

  defp check_engine_initialized(request, handler) do
    if document_request?(request) do
      projects = Store.projects()

      with {:ok, context} <- Lookup.resolve_from_request(request, projects) do
        if !Handler.requires_engine?(handler) or Store.ready?(context.project) do
          {:ok, context}
        else
          {:error, :engine_not_initialized, context.project}
        end
      end
    else
      {:ok, nil}
    end
  end

  defp document_request?(%{document: %Forge.Document{}}), do: true

  defp document_request?(%{params: params}) do
    document_request?(params)
  end

  defp document_request?(%{text_document: %{uri: _}}), do: true

  # These code actions carry a document uri in their data payload, so we treat them as document
  # requests by virtue of that uri (rather than by strict LSP taxonomy). Scoped to the "refactor"
  # provider for now so other requests are unaffected; can be broadened later.
  defp document_request?(%Structures.CodeAction{data: %{"provider" => "refactor", "uri" => uri}})
       when is_binary(uri) do
    true
  end

  defp document_request?(_), do: false

  def handle_notification(%GenLSP.Notifications.Initialized{}, lsp) do
    Logger.info("Server initialized, registering capabilities")
    registrations = registrations()

    if nil != GenLSP.request(lsp, registrations) do
      Logger.error("Failed to register capability")
    end

    for project <- Store.projects() do
      if !Store.blocked?(project) do
        started =
          Task.Supervisor.start_child(:expert_task_queue, fn ->
            Logger.info("Starting project", project: project)

            start_result = Expert.Project.Supervisor.ensure_node_started(project)

            send(lsp.pid, {:engine_initialized, project, start_result})
          end)

        case started do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Failed to start project initialization for #{Project.name(project)}: #{inspect(reason)}"
            )
        end
      end
    end

    {:noreply, lsp}
  end

  def handle_notification(%mod{} = notification, lsp) when mod in @server_specific_messages do
    old_state = assigns(lsp).state

    with {:ok, notification} <- Convert.to_native(notification),
         {:ok, new_state} <- apply_to_state(old_state, notification) do
      {:noreply, assign(lsp, state: new_state)}
    else
      error ->
        message = "Failed to handle #{notification.method}, #{inspect(error)}"
        Logger.error(message)

        {:noreply, lsp}
    end
  end

  def handle_notification(%GenLSP.Notifications.DollarSetTrace{}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(notification, lsp) do
    Logger.info("Unhandled notification: #{notification.method}")
    {:noreply, lsp}
  end

  def handle_info({:engine_initialized, project, {:ok, _pid}}, lsp) do
    Store.transition(project, :ready)

    State.propagate_elixir_source_path_for(project)

    Logger.info(
      "Engine initialized for project #{Project.name(project)}",
      project: project
    )

    {:noreply, lsp}
  end

  def handle_info({:deps_error, project, _details}, lsp) do
    {:noreply, maybe_prompt_deps_fetch(lsp, project)}
  end

  def handle_info({:deps_fetch_failed, project, message}, lsp) do
    {:noreply, prompt_deps_fetch_retry(lsp, project, message)}
  end

  def handle_info({:engine_initialized, project, {:error, {:shutdown, :deps_error}}}, lsp) do
    Store.transition(project, :pending)

    log_error(
      lsp,
      project,
      "Engine failed due to dependency errors. Run 'mix deps.get' to fetch dependencies."
    )

    {:noreply, lsp}
  end

  def handle_info({:engine_initialized, project, {:error, reason}}, lsp) do
    Store.transition(project, :pending)

    error_message = initialization_error_message(reason)
    log_error(lsp, project, error_message)

    {:noreply, lsp}
  end

  defp maybe_prompt_deps_fetch(lsp, project) do
    state = assigns(lsp).state

    supports_show_message = show_message_supported?()
    auto_fetch_dependencies? = Expert.Configuration.auto_fetch_dependencies?()

    # Avoids spamming the user with the same prompt if they already declined
    deps_declined = State.deps_declined?(state, project)

    cond do
      auto_fetch_dependencies? and not Store.blocked?(project) ->
        Store.transition(project, :blocked)
        start_deps_fetch_task(lsp, project)

      supports_show_message and not deps_declined and not Store.blocked?(project) ->
        Store.transition(project, :blocked)

        response = prompt_deps_fetch(lsp, project)

        handle_deps_fetch_result(response, lsp, project)

      true ->
        if deps_declined do
          Logger.info(
            "Engine failed due to dependency errors, but user declined to fetch dependencies.",
            project: project
          )
        end

        if !supports_show_message do
          log_error(
            lsp,
            project,
            "Engine failed due to dependency errors, but client does not support showing messages. Run 'mix deps.get' to fetch dependencies for #{Project.name(project)} and then restart Expert or your editor."
          )
        end

        lsp
    end
  end

  defp handle_deps_fetch_result(
         %Structures.MessageActionItem{title: "Yes"},
         lsp,
         project
       ) do
    start_deps_fetch_task(lsp, project)
  end

  defp handle_deps_fetch_result(
         %Structures.MessageActionItem{title: "No"},
         lsp,
         project
       ) do
    Store.transition(project, :ready)

    Logger.info("User declined to run mix deps.get for #{Project.name(project)}",
      project: project
    )

    state = assigns(lsp).state
    new_state = State.mark_deps_declined(state, project)
    assign(lsp, state: new_state)
  end

  defp handle_deps_fetch_result(_, lsp, project) do
    Store.transition(project, :pending)

    Logger.info("Dismissed dependency fetch prompt for #{Project.name(project)}",
      project: project
    )

    lsp
  end

  defp start_deps_fetch_task(lsp, project) do
    case Task.Supervisor.start_child(:expert_task_queue, fn ->
           run_deps_fetch_recovery(lsp, project)
         end) do
      {:ok, _pid} ->
        lsp

      {:error, reason} ->
        Store.transition(project, :pending)

        log_error(
          lsp,
          project,
          "Failed to start dependency fetch task: #{inspect(reason)}"
        )

        lsp
    end
  end

  defp run_deps_fetch_recovery(lsp, project) do
    Logger.info("Running mix deps.get for #{Project.name(project)}", project: project)

    result =
      try do
        Expert.EngineApi.clean_and_fetch_deps(project)
      rescue
        error in ErlangError ->
          {:error, error.original}
      end

    case result do
      :ok ->
        Logger.info("mix deps.get completed successfully", project: project)

        Expert.Project.Supervisor.stop_node(project)

        Logger.info("Restarting engine for #{Project.name(project)}", project: project)
        start_result = Expert.Project.Supervisor.ensure_node_started(project, blocked?: false)
        send(lsp.pid, {:engine_initialized, project, start_result})

      {:error, msg} ->
        send(lsp.pid, {:deps_fetch_failed, project, "mix deps.get failed: #{inspect(msg)}"})

      error ->
        send(
          lsp.pid,
          {:deps_fetch_failed, project,
           "Unexpected error from clean_and_fetch_deps: #{inspect(error)}"}
        )
    end
  end

  defp prompt_deps_fetch(lsp, project) do
    project_name = Project.name(project)

    prompt_with_actions(
      lsp,
      "The Expert engine failed with errors on dependencies for project #{project_name}. Would you like to fetch them?",
      ["Yes", "No"]
    )
  end

  defp prompt_deps_fetch_retry(lsp, project, message) do
    Logger.error(message, project: project)

    response =
      prompt_with_actions(
        lsp,
        "Fetching dependencies for project #{Project.name(project)} failed. #{message}. Would you like to retry?",
        ["Retry", "Cancel"]
      )

    handle_deps_fetch_retry_result(response, lsp, project)
  end

  defp show_message_supported? do
    case Expert.Configuration.client_support(:show_message) do
      value when value in [false, nil] -> false
      _ -> true
    end
  end

  defp handle_deps_fetch_retry_result(
         %Structures.MessageActionItem{title: "Retry"},
         lsp,
         project
       ) do
    start_deps_fetch_task(lsp, project)
  end

  defp handle_deps_fetch_retry_result(
         %Structures.MessageActionItem{title: "Cancel"},
         lsp,
         project
       ) do
    Store.transition(project, :pending)

    state = assigns(lsp).state
    new_state = State.mark_deps_declined(state, project)

    Logger.info("Cancelled dependency fetch retry for #{Project.name(project)}", project: project)

    assign(lsp, state: new_state)
  end

  defp handle_deps_fetch_retry_result(_, lsp, project) do
    Store.transition(project, :pending)

    state = assigns(lsp).state
    new_state = State.mark_deps_declined(state, project)

    Logger.info("Dismissed dependency fetch retry prompt for #{Project.name(project)}",
      project: project
    )

    assign(lsp, state: new_state)
  end

  defp prompt_with_actions(lsp, message, actions) do
    GenLSP.request(
      lsp,
      %Requests.WindowShowMessageRequest{
        id: Id.next(),
        params: %Structures.ShowMessageRequestParams{
          type: Enumerations.MessageType.error(),
          message: message,
          actions: Enum.map(actions, &%Structures.MessageActionItem{title: &1})
        }
      },
      :infinity
    )
  end

  # When logging errors we also notify the client to display the message
  def log_error(lsp \\ get_lsp(), project, message) do
    Logger.error(message, project: project)

    GenLSP.notify(lsp, %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: Enumerations.MessageType.error(),
        message: "[#{Forge.Project.name(project)}] #{message}"
      }
    })
  end

  defp apply_to_state(%State{} = state, %{} = request_or_notification) do
    case State.apply(state, request_or_notification) do
      {:ok, response, new_state} ->
        {:ok, response, new_state}

      {:ok, new_state} ->
        {:ok, new_state}

      :ok ->
        {:ok, state}

      error ->
        {error, state}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp fetch_handler(%_{} = request) do
    case request do
      %Requests.TextDocumentReferences{} ->
        {:ok, Handlers.FindReferences}

      %Requests.TextDocumentFormatting{} ->
        {:ok, Handlers.Formatting}

      %Requests.TextDocumentCodeAction{} ->
        {:ok, Handlers.CodeAction}

      %Requests.CodeActionResolve{} ->
        {:ok, Handlers.CodeActionResolve}

      %Requests.TextDocumentCodeLens{} ->
        {:ok, Handlers.CodeLens}

      %Requests.TextDocumentCompletion{} ->
        {:ok, Handlers.Completion}

      %Requests.TextDocumentDefinition{} ->
        {:ok, Handlers.GoToDefinition}

      %Requests.TextDocumentImplementation{} ->
        {:ok, Handlers.GoToImplementation}

      %Requests.TextDocumentHover{} ->
        {:ok, Handlers.Hover}

      %Requests.WorkspaceExecuteCommand{} ->
        {:ok, Handlers.Commands}

      %Requests.TextDocumentDocumentSymbol{} ->
        {:ok, Handlers.DocumentSymbols}

      %Requests.TextDocumentFoldingRange{} ->
        {:ok, Handlers.CodeFolding}

      %GenLSP.Requests.WorkspaceSymbol{} ->
        {:ok, Handlers.WorkspaceSymbol}

      %request_module{} ->
        {:error, {:unhandled, request_module}}
    end
  end

  defp registrations do
    %Requests.ClientRegisterCapability{
      id: Id.next(),
      params: %GenLSP.Structures.RegistrationParams{
        registrations: [file_watcher_registration()]
      }
    }
  end

  @did_changed_watched_files_id "-42"
  @watched_extensions ~w(ex exs)
  defp file_watcher_registration do
    extension_glob = "{" <> Enum.join(@watched_extensions, ",") <> "}"

    watchers = [
      %Structures.FileSystemWatcher{glob_pattern: "**/mix.lock"},
      %Structures.FileSystemWatcher{glob_pattern: "**/*.#{extension_glob}"}
    ]

    %Structures.Registration{
      id: @did_changed_watched_files_id,
      method: "workspace/didChangeWatchedFiles",
      register_options: %Structures.DidChangeWatchedFilesRegistrationOptions{watchers: watchers}
    }
  end

  defp initialization_error_message({:shutdown, {:failed_to_start_child, child, reason}}) do
    case child do
      {Expert.Project.Node, node_name} ->
        node_initialization_message(node_name, reason)

      child ->
        "Failed to start child #{inspect(child)}: #{inspect(reason)}"
    end
  end

  defp initialization_error_message(reason) do
    "Failed to initialize: #{inspect(reason)}"
  end

  defp node_initialization_message(name, reason) do
    case reason do
      # Build script failed (exit status) or max retry attempts reached
      {:error, message, output} when is_binary(message) and is_binary(output) ->
        details = output |> String.trim()

        if details == "" do
          "Engine build failed for #{name}.\n#{message}"
        else
          "Engine build failed for #{name}.\n#{message}\n\n#{details}"
        end

      # NOTE: ~c"could not compile dependency :elixir_sense..."
      {:error, :normal, message} ->
        "Engine #{name} initialization failed with error:\n\n#{message}"

      # NOTE: ** (Mix.Error) httpc request failed with: ...Could not install Hex because Mix could not download...
      {{:shutdown, {:error, :normal, message}}, _} ->
        "Engine #{name} shut down with error:\n\n#{message}"

      {{:shutdown, :deps_error}, _} ->
        "Engine #{name} failed due to dependency errors. Run 'mix deps.get' to fetch dependencies."

      {{:shutdown, {:node_exit, node_exit}}, _} ->
        "Engine #{name} exit with status #{node_exit.status}, last message:\n\n#{node_exit.last_message}"

      {:shutdown, {:bootstrap_error, message}} ->
        message

      reason ->
        "Failed to start engine #{name}: #{inspect(reason)}"
    end
  end
end
