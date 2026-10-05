defmodule Expert.Project.EngineRuntime do
  use Supervisor

  alias Expert.Configuration
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Expert.Project.Intelligence
  alias Expert.Project.Node
  alias Expert.Project.SearchListener
  alias Expert.Project.Store
  alias Forge.Project

  @doc "Returns whether project code can run through an initialized Engine."
  def available?(%Project{} = project) do
    Configuration.compilation_enabled?() and Store.ready?(project) and
      is_pid(Process.whereis(EngineNode.name(project)))
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::engine_runtime"

  def start_link(%Project{} = project) do
    Store.transition(project, :pending)
    Supervisor.start_link(__MODULE__, project, name: name(project))
  end

  @impl Supervisor
  def init(%Project{} = project) do
    children = [
      {EngineSupervisor, project},
      {Node, project},
      {Intelligence, project},
      {SearchListener, project}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
