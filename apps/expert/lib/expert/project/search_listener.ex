defmodule Expert.Project.SearchListener do
  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project.Diagnostics
  alias Expert.Project.Indexer
  alias Expert.Project.Node
  alias Expert.Project.Reindex
  alias Expert.Project.Store
  alias Forge.Project

  require Logger

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  def name(%Project{} = project) do
    :"#{Project.unique_name(project)}::search_listener"
  end

  @impl GenServer
  def init([%Project{} = project]) do
    Diagnostics.register(project)

    EngineApi.register_listener(project, self(), [
      project_compiled(),
      search_store_loading(),
      file_compile_requested(),
      filesystem_event()
    ])

    if Configuration.compilation_enabled?(), do: Store.transition(project, :ready)

    {:ok, project, {:continue, :compile}}
  end

  @impl GenServer
  def handle_continue(:compile, project) do
    if Configuration.compilation_enabled?() do
      Node.trigger_build(project, false)
    end

    {:noreply, project}
  end

  @impl GenServer
  def handle_info(project_compiled(status: status), %Project{} = project)
      when status in [:success, :successful, :error] do
    Indexer.refresh(project)
    {:noreply, project}
  end

  def handle_info(search_store_loading(), %Project{} = project) do
    message = "Search index is loading for #{Project.name(project)}..."
    Logger.info(message)

    GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: GenLSP.Enumerations.MessageType.info(),
        message: message
      }
    })

    {:noreply, project}
  end

  def handle_info(file_compile_requested() = message, %Project{} = project) do
    send(Reindex.name(project), message)
    {:noreply, project}
  end

  def handle_info(filesystem_event() = message, %Project{} = project) do
    send(Reindex.name(project), message)
    {:noreply, project}
  end
end
