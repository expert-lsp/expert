defmodule Expert.Project.SearchListener do
  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Suggestions
  alias Expert.Protocol.Id
  alias Forge.Formats
  alias Forge.Project
  alias GenLSP.Requests

  require Logger

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  defp name(%Project{} = project) do
    :"#{Project.unique_name(project)}::search_listener"
  end

  @impl GenServer
  def init([%Project{} = project]) do
    EngineApi.register_listener(project, self(), [
      project_index_ready(),
      project_reindex_requested(),
      project_reindexed(),
      search_store_loading()
    ])

    {:ok, %{project: project, extensions_suggested?: false}}
  end

  # An index that runs before the dependencies compile finds none of their
  # modules, so the suggestion waits for one that does.
  @impl GenServer
  def handle_info(project_index_ready(), %{extensions_suggested?: false} = state) do
    case Suggestions.dependencies(state.project) do
      [] ->
        {:noreply, state}

      dependencies ->
        show_message(
          "Add these dependencies to #{Project.name(state.project)} for completion and " <>
            "navigation that read the project:\n" <> Enum.join(dependencies, "\n")
        )

        {:noreply, %{state | extensions_suggested?: true}}
    end
  end

  def handle_info(project_index_ready(), state), do: {:noreply, state}

  def handle_info(project_reindex_requested(), state) do
    Logger.info("project reindex requested")
    GenLSP.request(Expert.get_lsp(), %Requests.WorkspaceCodeLensRefresh{id: Id.next()})

    {:noreply, state}
  end

  def handle_info(project_reindexed(elapsed_ms: elapsed), %{project: project} = state) do
    message = "Reindexed #{Project.name(project)} in #{Formats.time(elapsed, unit: :millisecond)}"
    Logger.info(message)
    GenLSP.request(Expert.get_lsp(), %Requests.WorkspaceCodeLensRefresh{id: Id.next()})
    show_message(message)

    {:noreply, state}
  end

  def handle_info(search_store_loading(), %{project: project} = state) do
    message = "Search index is loading for #{Project.name(project)}..."
    Logger.info(message)
    show_message(message)

    {:noreply, state}
  end

  defp show_message(message) do
    GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: GenLSP.Enumerations.MessageType.info(),
        message: message
      }
    })
  end
end
