defmodule Engine.ManagerApi do
  @moduledoc """
  Engine-node API for operations owned by the manager node.
  """

  alias Engine.Dispatch
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @search_timeout 5_000

  @spec search_store_exact(Project.t(), Entry.subject_query(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_exact(%Project{} = project, subject \\ :_, constraints) do
    Dispatch.erpc_call(
      Expert.Search.Store,
      :exact,
      [project, subject, constraints],
      @search_timeout
    )
  end

  @spec search_store_prefix(Project.t(), String.t(), Entry.constraints()) ::
          {:ok, [Entry.t()]} | {:error, term()} | []
  def search_store_prefix(%Project{} = project, prefix, constraints) do
    Dispatch.erpc_call(
      Expert.Search.Store,
      :prefix,
      [project, prefix, constraints],
      @search_timeout
    )
  end
end
