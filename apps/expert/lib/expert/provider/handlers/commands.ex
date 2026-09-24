defmodule Expert.Provider.Handlers.Commands do
  @behaviour Expert.Provider.Handler

  alias Expert.Project.Reindex
  alias Expert.Project.Store
  alias Forge.Project
  alias GenLSP.Enumerations.ErrorCodes
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @reindex_name "Reindex"
  @connection_details_name "connectionDetails"

  def names do
    [@reindex_name, @connection_details_name]
  end

  def reindex_command(%Project{} = project) do
    project_name = Project.name(project)

    %Structures.Command{
      title: "Rebuild #{project_name}'s code search index",
      command: @reindex_name
    }
  end

  @impl Expert.Provider.Handler
  def handle(
        %Requests.WorkspaceExecuteCommand{
          params: %Structures.ExecuteCommandParams{} = params
        },
        _context
      ) do
    projects = Store.projects()

    response =
      case params.command do
        @reindex_name ->
          project_names = Enum.map_join(projects, ", ", &Project.name/1)
          Logger.info("Reindex #{project_names}")
          reindex_all(projects)

        @connection_details_name ->
          epmd_module = Forge.EPMD

          with {:ok, _} <- Expert.Clustering.start_net_kernel(),
               module_path when is_list(module_path) <- :code.which(epmd_module) do
            ebin_path = module_path |> to_string() |> Path.dirname()
            priv_dir = :code.priv_dir(Application.get_application(__MODULE__))
            script_ext = if Forge.OS.windows?(), do: ".bat", else: ".sh"
            remote_shell_script_path = Path.join(priv_dir, "remote_shell#{script_ext}")
            node_name = to_string(Node.self())
            port = Forge.EPMD.dist_port()
            cookie = to_string(Node.get_cookie())
            epmd_module_name = Atom.to_string(epmd_module)

            %{
              "nodeName" => node_name,
              "port" => port,
              "cookie" => cookie,
              "epmdModule" => epmd_module_name,
              "epmdEbinPath" => ebin_path,
              "debugScriptPath" => remote_shell_script_path,
              "command" =>
                [
                  remote_shell_script_path,
                  node_name,
                  port,
                  epmd_module_name,
                  ebin_path,
                  cookie
                ]
                |> Enum.map_join(
                  " ",
                  &shell_quote/1
                )
                |> prepend_amp_on_windows()
            }
          else
            :non_existing ->
              internal_error("failed to find ebin path for #{epmd_module}")

            {:error, reason} ->
              internal_error("failed to start node: #{inspect(reason)}")
          end

        invalid ->
          message = "#{invalid} is not a valid command"
          internal_error(message)
      end

    {:ok, response}
  end

  defp reindex_all(projects) do
    Enum.reduce_while(projects, :ok, fn project, _ ->
      case Reindex.perform(project) do
        :ok ->
          {:cont, "ok"}

        error ->
          GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
            params: %GenLSP.Structures.ShowMessageParams{
              type: GenLSP.Enumerations.MessageType.error(),
              message: "Indexing #{Project.name(project)} failed"
            }
          })

          Logger.error("Indexing command failed due to #{inspect(error)}")

          {:halt, internal_error("Could not reindex: #{error}")}
      end
    end)
  end

  defp internal_error(message) do
    %GenLSP.ErrorResponse{code: ErrorCodes.internal_error(), message: message}
  end

  defp shell_quote(value) do
    "'" <> (value |> to_string() |> String.replace("'", "'\\''")) <> "'"
  end

  defp prepend_amp_on_windows(command) do
    if Forge.OS.windows?(), do: "& " <> command, else: command
  end
end
