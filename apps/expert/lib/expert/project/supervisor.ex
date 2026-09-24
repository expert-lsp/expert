defmodule Expert.Project.Supervisor do
  use Supervisor

  alias Expert.EngineSupervisor
  alias Expert.Project.Diagnostics
  alias Expert.Project.Indexer
  alias Expert.Project.Intelligence
  alias Expert.Project.Node
  alias Expert.Project.Reindex
  alias Expert.Project.SearchListener
  alias Expert.Project.Store
  alias Expert.Search
  alias Forge.Project

  require Logger

  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project, name: name(project))
  end

  def init(%Project{} = project) do
    children = [
      {EngineSupervisor, project},
      {Node, project},
      {Search.Store.backend(), project},
      {Search.Store, [project]},
      {Diagnostics, project},
      {Intelligence, project},
      {SearchListener, project},
      {Reindex, project},
      {Task.Supervisor, name: Indexer.task_supervisor_name(project)},
      {Indexer, [project, initial_compile?: true]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start(%Project{} = project) do
    DynamicSupervisor.start_child(Expert.Project.DynamicSupervisor.name(), {__MODULE__, project})
  end

  def stop(%Project{} = project) do
    pid =
      project
      |> name()
      |> Process.whereis()

    DynamicSupervisor.terminate_child(Expert.Project.DynamicSupervisor.name(), pid)
  end

  def name(%Project{} = project) do
    :"#{Project.unique_name(project)}::supervisor"
  end

  def ensure_node_started(%Project{} = project) do
    ensure_node_started(project, blocked?: true)
  end

  def ensure_node_started(%Project{} = project, opts) when is_list(opts) do
    blocked? = Keyword.get(opts, :blocked?, true)

    if blocked? and Store.blocked?(project) do
      Logger.info("Project node start blocked for #{Project.name(project)}")
      {:error, :deps_error}
    else
      case start(project) do
        {:ok, pid} ->
          Store.transition(project, :ready)
          Logger.info("Started project node for #{Project.name(project)}")
          {:ok, pid}

        {:error, {reason, pid}} when reason in [:already_started, :already_present] ->
          Store.transition(project, :ready)
          {:ok, pid}

        {:error, reason} ->
          Logger.error(
            "Failed to start project node for #{Project.name(project)}: #{inspect(reason, pretty: true)}"
          )

          {:error, reason}
      end
    end
  end

  def stop_node(%Project{} = project) do
    stop(project)
    Store.transition(project, :pending)

    Logger.info("Stopping project node for #{Project.name(project)}")
  end

  def restart_node(%Project{} = project, opts \\ []) when is_list(opts) do
    if Process.whereis(name(project)) do
      stop_node(project)
    end

    ensure_node_started(project, opts)
  end
end
