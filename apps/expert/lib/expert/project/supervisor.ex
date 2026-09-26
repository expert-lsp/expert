defmodule Expert.Project.Supervisor do
  use Supervisor

  alias Expert.Configuration
  alias Expert.Project.Diagnostics
  alias Expert.Project.EngineRuntime
  alias Expert.Project.Indexer
  alias Expert.Project.MixProject
  alias Expert.Project.Reindex
  alias Expert.Project.Store
  alias Expert.Search
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Project

  require Logger

  def start_link(%Project{} = project) do
    with {:ok, versions} <- MixProject.runtime_versions(project),
         {:ok, pid} <- Supervisor.start_link(__MODULE__, {project, versions}, name: name(project)) do
      maybe_start_configured_engine(project)
      {:ok, pid}
    end
  end

  @impl Supervisor
  def init({%Project{} = project, versions}) do
    children = [
      %{
        id: {__MODULE__, :manager, Project.unique_name(project)},
        start: {__MODULE__, :start_manager_supervisor, [project, versions]},
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def start_manager_supervisor(%Project{} = project, versions) do
    children = [
      {Search.Store.backend(), [project, runtime_versions: versions]},
      {Search.Store, [project]},
      {ModuleRegistry, project},
      {Diagnostics, project},
      {Reindex, project},
      {Task.Supervisor, name: Indexer.task_supervisor_name(project)},
      {Indexer, project}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one)
  end

  def start(%Project{} = project) do
    DynamicSupervisor.start_child(Expert.Project.DynamicSupervisor.name(), {__MODULE__, project})
  end

  def stop(%Project{} = project) do
    DynamicSupervisor.terminate_child(
      Expert.Project.DynamicSupervisor.name(),
      Process.whereis(name(project))
    )
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::supervisor"

  def ensure_node_started(%Project{} = project, opts \\ []) do
    case ensure_supervisor(project) do
      {:ok, pid, status} ->
        if Keyword.get(opts, :blocked?, true) and Store.blocked?(project) and
             Configuration.compilation_enabled?() do
          Logger.info("Project start blocked for #{Project.name(project)}")
          {:error, :deps_error}
        else
          result = if status == :started, do: :ok, else: set_engine_state(project)

          case result do
            :ok ->
              {:ok, pid}

            {:error, reason} ->
              Logger.error("Failed to start Engine: #{inspect(reason)}")
              {:ok, pid}
          end
        end

      {:error, reason} = error ->
        Logger.error("Failed to start project for #{Project.name(project)}: #{inspect(reason)}")
        error
    end
  end

  def stop_node(%Project{} = project) do
    Store.transition(project, :pending)
    result = stop(project)
    Logger.info("Stopping project #{Project.name(project)}")
    result
  end

  def restart_node(%Project{} = project, opts \\ []) do
    if Process.whereis(name(project)), do: stop_node(project)
    ensure_node_started(project, opts)
  end

  def start_engine(%Project{} = project) do
    with {:ok, _pid, _status} <- ensure_supervisor(project) do
      start_engine_child(project)
    end
  end

  def stop_engine(%Project{} = project) do
    with {:ok, _pid, _status} <- ensure_supervisor(project) do
      stop_engine_child(project)
    end
  end

  def restart_engine(%Project{} = project) do
    with {:ok, pid, _status} <- ensure_supervisor(project),
         :ok <- stop_engine_child(project),
         :ok <- start_engine_child(project) do
      {:ok, pid}
    end
  end

  defp ensure_supervisor(project) do
    case start(project) do
      {:ok, pid} ->
        {:ok, pid, :started}

      {:error, {reason, pid}} when reason in [:already_started, :already_present] ->
        {:ok, pid, :existing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_engine_state(project) do
    if Configuration.compilation_enabled?() do
      start_engine_child(project)
    else
      stop_engine_child(project)
    end
  end

  defp start_engine_child(project) do
    if Store.blocked?(project), do: :ok, else: do_start_engine_child(project)
  end

  defp do_start_engine_child(project) do
    case Supervisor.start_child(name(project), {EngineRuntime, project}) do
      {:ok, _pid} ->
        Logger.info("Started Engine for #{Project.name(project)}")
        stop_engine_if_disabled(project)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        restart_engine_child(project)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_engine_if_disabled(project) do
    if Configuration.compilation_enabled?(), do: :ok, else: stop_engine_child(project)
  end

  defp stop_engine_child(project) do
    Store.transition(project, :pending)

    case Supervisor.terminate_child(name(project), EngineRuntime) do
      :ok ->
        :ok = Supervisor.delete_child(name(project), EngineRuntime)

      {:error, :not_found} ->
        :ok
    end

    Indexer.refresh(project)
  end

  defp restart_engine_child(project) do
    case Supervisor.restart_child(name(project), EngineRuntime) do
      {:ok, _pid} -> stop_engine_if_disabled(project)
      {:ok, _pid, _info} -> stop_engine_if_disabled(project)
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_configured_engine(project) do
    if Configuration.compilation_enabled?() and not Store.blocked?(project) do
      case start_engine_child(project) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Failed to start Engine: #{inspect(reason)}")
      end
    end
  end
end
