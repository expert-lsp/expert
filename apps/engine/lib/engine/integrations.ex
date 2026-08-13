defmodule Engine.Integrations do
  @moduledoc """
  Registers third party integrations.
  """

  alias Forge.Ast.Env
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry

  @callback index(binary(), map(), String.t()) :: [Entry.t()]

  @callback complete(Env.t()) ::
              {:augment | :override, [{struct(), [atom()]}], boolean(), [atom()]} | :ignore

  @callback hover(Env.t()) :: [{String.t(), Range.t()}]

  @optional_callbacks index: 3, complete: 1, hover: 1

  @beam_indexers [Engine.Integrations.Spark.Indexer]
  @indexer_module_names @beam_indexers |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  @completion_providers [Engine.Integrations.Spark.Completion]
  @hover_providers [Engine.Integrations.Spark.Hover]

  def indexer_module_names, do: @indexer_module_names

  def index_beam(binary, metadata, source_path) do
    Enum.flat_map(@beam_indexers, & &1.index(binary, metadata, source_path))
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
