defmodule Expert.Integrations do
  @moduledoc """
  Registers built-in integrations.
  """

  alias Forge.Ast.Env
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @callback index(Project.t(), binary(), map(), String.t()) :: [Entry.t()]

  @callback complete(Env.t()) ::
              {:augment | :override, [{struct(), [atom()]}], boolean(), [atom()]} | :ignore

  @callback hover(Env.t()) :: [{String.t(), Range.t()}]

  @optional_callbacks index: 4, complete: 1, hover: 1

  @integrations [
    {Expert.Integrations.Spark.Indexer, [:index]},
    {Expert.Integrations.Spark.Completion, [:complete]},
    {Expert.Integrations.Spark.Hover, [:hover]}
  ]

  @beam_indexers for {module, capabilities} <- @integrations,
                     :index in capabilities,
                     do: module

  @completion_providers for {module, capabilities} <- @integrations,
                            :complete in capabilities,
                            do: module

  @hover_providers for {module, capabilities} <- @integrations,
                       :hover in capabilities,
                       do: module

  @indexer_module_names @beam_indexers |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  def indexer_module_names, do: @indexer_module_names

  def index_beam(project, binary, metadata, source_path) do
    Enum.flat_map(@beam_indexers, & &1.index(project, binary, metadata, source_path))
  end

  def complete(env) do
    Enum.find_value(@completion_providers, :ignore, fn provider ->
      case provider.complete(env) do
        :ignore -> nil
        result -> result
      end
    end)
  end

  def hover(env) do
    Enum.flat_map(@hover_providers, & &1.hover(env))
  end
end
