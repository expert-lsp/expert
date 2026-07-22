defmodule Engine.Bootstrap do
  @moduledoc """
  Bootstraps the remote control node boot sequence.

  We need to first start elixir and mix, then load the project's mix.exs file so we can discover
  the project's code paths, which are then added to the code paths from the language server. At this
  point, it's safe to start the project, as we should have all the code present to compile the system.
  """
  alias Engine.Build
  alias Engine.Build.Isolation
  alias Forge.Document
  alias Forge.LogFilter
  alias Forge.Project

  def init(
        %Project{} = project,
        document_store_entropy,
        app_configs,
        manager_node,
        logger_global_metadata
      ) do
    :logger.update_primary_config(%{metadata: logger_global_metadata})

    Forge.Document.Store.set_entropy(document_store_entropy)

    Application.put_all_env(app_configs)

    maybe_append_hex_path()

    project_root = Project.root_path(project)

    with :ok <- File.cd(project_root),
         {:ok, _} <- Application.ensure_all_started(:elixir),
         {:ok, _} <- Application.ensure_all_started(:mix),
         {:ok, _} <- Application.ensure_all_started(:logger) do
      project = maybe_load_mix_exs(project)

      with :ok <- Project.ensure_workspace(project) do
        Engine.set_project(project)
        Engine.set_manager_node(manager_node)
        Mix.env(:test)
        set_mix_build_path(project)

        maybe_load_project_config(project)

        ExUnit.start()
        start_logger(project)
        maybe_change_directory(project)
        :ok
      end
    end
  end

  defp maybe_load_project_config(%Project{kind: :mix} = project) do
    Engine.Mix.in_project(project, fn _ -> Mix.Task.run(:loadconfig) end)
  end

  defp maybe_load_project_config(%Project{}) do
    :ok
  end

  # There is a bug in elixir 1.19.1 where the partition child processes
  # for parallel dependency compilation do not inherit the parent process's
  # Mix.Project config, which causes them to write compiled artifacts to the
  # default _build directory instead of expert build path.
  # This ensures the build path is set regardless of elixir version.
  defp set_mix_build_path(%Project{} = project) do
    versioned_build = Project.versioned_build_path(project)
    build_path = Path.join(versioned_build, Atom.to_string(Mix.env()))
    System.put_env("MIX_BUILD_PATH", build_path)
  end

  defp maybe_append_hex_path do
    hex_ebin = Path.join(["hex-*", "**", "ebin"])

    hex_path =
      :archives
      |> Mix.path_for()
      |> Path.join(hex_ebin)
      |> Path.wildcard()

    case hex_path do
      [archives] -> Code.append_path(archives)
      _ -> :ok
    end
  end

  defp start_logger(%Project{} = project) do
    log_file_name =
      project
      |> Project.workspace_path("project.log")
      |> String.to_charlist()

    handler_name = :"#{Project.name(project)}_handler"

    config = %{
      config: %{
        file: log_file_name,
        max_no_bytes: 1_000_000,
        max_no_files: 1
      },
      formatter: Logger.Formatter.new(metadata: [:instance_id]),
      level: :info
    }

    :logger.add_handler(handler_name, :logger_std_h, config)
    LogFilter.hook_into_logger()
  end

  defp maybe_change_directory(%Project{kind: :mix} = project) do
    current_dir = File.cwd!()

    # Note about the following code:
    # I tried a bunch of stuff to get it to work, like checking if the
    # app is an umbrella (umbrella? returns false when started in a subapp)
    # to no avail. This was the only thing that consistently worked
    {:ok, configured_root} =
      Engine.Mix.in_project(project, fn _ ->
        Mix.Project.config()
        |> Keyword.get(:config_path)
        |> Path.dirname()
        |> Path.join("..")
        |> Path.expand()
      end)

    if current_dir != configured_root do
      File.cd!(configured_root)
    end
  end

  defp maybe_change_directory(%Project{}) do
    :ok
  end

  defp maybe_load_mix_exs(%Project{} = project) do
    # The reason this function exists is to support projects that have the same name as
    # one of their dependencies. Prior to this, the project name was based off the directory
    # name of the project, and if that's the same as a dependency, the mix project stack will
    # raise an error during `deps.safe_compile`, as a project with the same name was already defined.
    # Mix itself uses the name of the module that the mix.exs defines as the project name, and I figured
    # this was a safe default.

    case Project.mix_exs_path(project) do
      path when is_binary(path) ->
        compiler_options = Code.compiler_options()
        target = Mix.target()

        {compile_result, diagnostics} =
          case Isolation.invoke(fn -> compile_mix_exs(path) end) do
            {:ok, result} -> result
            {:error, reason} -> {{:error, reason}, []}
          end

        # We've found the mix project module, but it's now been added to the
        # project stack. We need to clear the stack because we use `in_mix_project`, and
        # that will fail if the current project is already in the project stack.
        # Restarting mix will clear the stack without using private APIs.
        Application.stop(:mix)
        Application.ensure_all_started(:mix)

        case compile_result do
          {:ok, compiled} ->
            case find_mix_project_module(compiled) do
              nil ->
                reject_mix_project(
                  project,
                  path,
                  compiler_options,
                  target,
                  diagnostics,
                  :no_mix_project
                )

              project_module ->
                project = Project.set_project_module(project, project_module)
                Engine.Mix.accept_project(project, compiled)
                project
            end

          {:error, reason} ->
            reject_mix_project(project, path, compiler_options, target, diagnostics, reason)
        end

      nil ->
        project
    end
  end

  defp compile_mix_exs(path) do
    Code.with_diagnostics(fn -> do_compile_mix_exs(path) end)
  end

  defp do_compile_mix_exs(path) do
    {:ok, Code.compile_file(path)}
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
  end

  defp ensure_diagnostics(diagnostics, path, reason) do
    if Enum.any?(diagnostics, &match?(%{severity: :error}, &1)) do
      diagnostics
    else
      diagnostics ++ [error_diagnostic(path, reason)]
    end
  end

  defp error_diagnostic(path, reason) do
    message =
      case reason do
        :no_mix_project -> "mix.exs does not define a Mix project"
        {:error, exception, _stack} -> Exception.message(exception)
        other -> "mix.exs compilation failed: #{inspect(other)}"
      end

    %{file: path, source: path, position: 1, severity: :error, message: message}
  end

  defp reject_mix_project(
         %Project{} = project,
         path,
         compiler_options,
         target,
         diagnostics,
         reason
       ) do
    document = Document.new(Document.Path.to_uri(path), File.read!(path), 0)

    diagnostics =
      document
      |> Build.Error.diagnostics_from_mix(ensure_diagnostics(diagnostics, path, reason))
      |> Build.Error.refine_diagnostics()

    Engine.Mix.put_initial_project_diagnostics(diagnostics)
    Code.compiler_options(compiler_options)
    Mix.target(target)
    Engine.Mix.discard_project_modules(path)
    %Project{project | kind: :bare, project_module: nil}
  end

  defp find_mix_project_module(modules) do
    case Enum.find(modules, fn {module, _bytecode} -> function_exported?(module, :project, 0) end) do
      {module, _bytecode} -> module
      nil -> nil
    end
  end
end
