defmodule Expert.Integrations.Cache do
  @moduledoc """
  Stores project-scoped values for integrations.
  """

  use GenServer

  alias Forge.Project

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def fetch(%Project{} = project, namespace, key, fetch)
      when is_atom(namespace) and is_function(fetch, 0) do
    table = name(project)
    cache_key = {namespace, key}

    case :ets.lookup(table, cache_key) do
      [{^cache_key, value}] ->
        value

      [] ->
        value = fetch.()

        if value != :error do
          true = :ets.insert(table, {cache_key, value})
        end

        value
    end
  end

  def clear(%Project{} = project) do
    :ets.delete_all_objects(name(project))
    :ok
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::integration_cache"

  @impl GenServer
  def init(project) do
    table =
      :ets.new(name(project), [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end
end
