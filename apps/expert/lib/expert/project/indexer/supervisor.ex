defmodule Expert.Project.Indexer.Supervisor do
  @moduledoc false

  use Supervisor

  alias Expert.Project.Indexer
  alias Forge.Project

  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project)
  end

  @impl Supervisor
  def init(%Project{} = project) do
    children = [
      {Task.Supervisor, name: Indexer.task_supervisor_name(project)},
      {Indexer, project}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
