defmodule Engine.Build.State do
  import Forge.EngineApi.Messages

  alias Elixir.Features
  alias Engine.Build
  alias Forge.Diagnostic
  alias Forge.Document
  alias Forge.Project
  alias Forge.VM.Versions

  require Logger

  defstruct project: nil,
            build_number: 0,
            uri_to_document: %{},
            project_compile: :none,
            initial_compile?: true,
            last_deps_fetch_result: nil

  def new(%Project{} = project) do
    %__MODULE__{project: project}
  end

  def on_timeout(%__MODULE__{} = state) do
    new_state =
      case state.project_compile do
        :none -> state
        :force -> compile_project(state, true)
        :normal -> compile_project(state, false)
      end

    # We need to compile the individual documents even after the project is
    # compiled because they might have unsaved changes, and we want that state
    # to be the latest state of the project.
    new_state =
      Enum.reduce(new_state.uri_to_document, new_state, fn {_uri, document}, state ->
        compile_file(state, document)
      end)

    %{new_state | uri_to_document: %{}, project_compile: :none}
  end

  def on_file_compile(%__MODULE__{} = state, %Document{} = document) do
    %__MODULE__{
      state
      | uri_to_document: Map.put(state.uri_to_document, document.uri, document)
    }
  end

  def on_project_compile(%__MODULE__{} = state, force?) do
    if force? do
      %__MODULE__{state | project_compile: :force}
    else
      %__MODULE__{state | project_compile: :normal}
    end
  end

  def ensure_build_directory(%__MODULE__{} = state) do
    # If the project directory isn't there, for some reason the main build fails, so we create it here
    # to ensure that the build will succeed.
    project = state.project
    build_path = Project.versioned_build_path(project)

    case Versions.check_erlang_compatibility(build_path) do
      :compatible ->
        :ok

      {:incompatible, tagged, current} ->
        Logger.info(
          "Build path #{build_path} was compiled with Erlang #{tagged}, " <>
            "but current Erlang is #{current}. Deleting"
        )

        File.rm_rf(build_path)

      :untagged ->
        :ok

      {:unreadable, _error} ->
        Logger.info("Build path #{build_path} has unreadable version tags. Deleting")
        File.rm_rf(build_path)
    end

    maybe_delete_old_builds(project)

    if !File.exists?(build_path) do
      File.mkdir_p!(build_path)
      Versions.write(build_path)
    end
  end

  def fetch_deps(%__MODULE__{} = state, project) do
    build_path = Project.versioned_build_path(project)

    Logger.info("Cleaning build directory: #{build_path}")

    case File.rm_rf(build_path) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove build path #{path}: #{inspect(reason)}")
    end

    result = Engine.Build.Project.fetch_deps(project)

    %{state | last_deps_fetch_result: result}
  end

  def last_deps_fetch_result(%__MODULE__{last_deps_fetch_result: result}), do: result

  def edit_window_millis do
    Application.get_env(:engine, :edit_window_millis, 100)
  end

  defp compile_project(%__MODULE__{} = state, force?) do
    state = increment_build_number(state)
    project = state.project

    project =
      Build.with_lock(fn ->
        compile_requested_message =
          project_compile_requested(project: project, build_number: state.build_number)

        Engine.broadcast(compile_requested_message)
        Engine.Compilation.TraceBuffer.discard()

        {elapsed_us, result} =
          :timer.tc(fn -> Build.Project.compile(project, state.initial_compile?, force?) end)

        elapsed_ms = to_ms(elapsed_us)
        project = Engine.get_project() || project

        {compile_message, diagnostics} =
          case result do
            :ok ->
              message =
                project_compiled(status: :success, project: project, elapsed_ms: elapsed_ms)

              {message, []}

            {:ok, diagnostics} ->
              message =
                project_compiled(status: :success, project: project, elapsed_ms: elapsed_ms)

              diagnostics =
                diagnostics
                |> List.wrap()
                |> Enum.filter(&match?(%Diagnostic{}, &1))

              {message, diagnostics}

            {:error, diagnostics} ->
              Engine.Compilation.TraceBuffer.discard()
              message = project_compiled(status: :error, project: project, elapsed_ms: elapsed_ms)

              diagnostics =
                diagnostics
                |> List.wrap()
                |> Enum.filter(&match?(%Diagnostic{}, &1))

              {message, diagnostics}
          end

        diagnostics_message =
          project_diagnostics(
            project: project,
            build_number: state.build_number,
            diagnostics: diagnostics
          )

        Engine.broadcast(compile_message)
        Engine.broadcast(diagnostics_message)
        project
      end)

    %__MODULE__{state | project: project, initial_compile?: false}
  end

  def compile_file(%__MODULE__{} = state, %Document{} = document) do
    state = increment_build_number(state)
    project = state.project

    Build.with_lock(fn ->
      Engine.broadcast(file_compile_requested(uri: document.uri))

      {elapsed_us, result} = :timer.tc(fn -> compile_document(project, document) end)

      elapsed_ms = to_ms(elapsed_us)

      {status, diagnostics} =
        case result do
          {:ok, diagnostics} ->
            {:success, diagnostics}

          {:error, :project_not_loaded} ->
            {:error, :unchanged}

          {:error, diagnostics} ->
            {:error, diagnostics}
        end

      Engine.broadcast(
        file_compiled(
          project: project,
          build_number: state.build_number,
          status: status,
          uri: document.uri,
          elapsed_ms: elapsed_ms
        )
      )

      if diagnostics != :unchanged do
        Engine.broadcast(
          file_diagnostics(
            project: project,
            build_number: state.build_number,
            uri: document.uri,
            diagnostics: List.wrap(diagnostics)
          )
        )
      end
    end)

    state
  end

  defp compile_document(%Project{kind: :mix}, document) do
    if Engine.Mix.project_file?(document.path) do
      Build.Document.compile(document)
    else
      Engine.Mix.in_project(fn _ -> Build.Document.compile(document) end)
    end
  end

  defp compile_document(%Project{}, document) do
    Build.Document.compile(document)
  end

  def set_compiler_options do
    Code.compiler_options(
      parser_options: parser_options(),
      tracers: [Engine.Compilation.Tracer]
    )

    :ok
  end

  def mix_compile_opts(force?) do
    opts = ~w(
        --return-errors
        --ignore-module-conflict
        --all-warnings
        --docs
        --debug-info
        --no-protocol-consolidation
        --no-prune-code-paths
    )

    if force? do
      ["--force" | opts]
    else
      opts
    end
  end

  defp to_ms(microseconds) do
    microseconds / 1000
  end

  defp parser_options do
    [columns: true]
  end

  defp increment_build_number(%__MODULE__{} = state) do
    %__MODULE__{state | build_number: state.build_number + 1}
  end

  @two_month_seconds 86_400 * 31 * 2
  defp maybe_delete_old_builds(%Project{} = project) do
    build_root = Project.build_path(project)
    two_months_ago = System.system_time(:second) - @two_month_seconds

    case File.ls(build_root) do
      {:ok, entries} ->
        for file_name <- entries,
            absolute_path = Path.join(build_root, file_name),
            File.dir?(absolute_path),
            newest_beam_mtime(absolute_path) <=
              two_months_ago do
          File.rm_rf!(absolute_path)
        end

      _ ->
        :ok
    end
  end

  defp newest_beam_mtime(directory) do
    directory
    |> Path.join("**/*.beam")
    |> Path.wildcard()
    |> then(fn
      [] ->
        0

      beam_files ->
        beam_files
        |> Enum.map(&File.stat!(&1, time: :posix).mtime)
        |> Enum.max()
    end)
  end
end
