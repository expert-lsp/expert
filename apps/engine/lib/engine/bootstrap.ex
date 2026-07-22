defmodule Engine.Bootstrap do
  @moduledoc """
  Bootstraps the remote control node boot sequence.

  We need to first start elixir and mix, then load the project's mix.exs file so we can discover
  the project's code paths, which are then added to the code paths from the language server. At this
  point, it's safe to start the project, as we should have all the code present to compile the system.
  """
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
      with :ok <- Project.ensure_workspace(project) do
        Engine.set_project(project)
        Engine.set_manager_node(manager_node)
        Mix.env(:test)
        set_mix_build_path(project)
        load_project(project)

        ExUnit.start()
        start_logger(project)
        maybe_change_directory(Engine.get_project())
        :ok
      end
    end
  end

  defp load_project(%Project{kind: :mix} = project) do
    Engine.Mix.reload_project(project)
  end

  defp load_project(%Project{}) do
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

  defp maybe_change_directory(%Project{project_module: nil}), do: :ok

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
end
