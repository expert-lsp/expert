defmodule Expert.EngineBuild.DynamicSupervisor do
  def name do
    Expert.EngineBuildSupervisor
  end

  def options do
    [name: name(), strategy: :one_for_one]
  end
end
