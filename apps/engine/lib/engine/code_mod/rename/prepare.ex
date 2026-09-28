defmodule Engine.CodeMod.Rename.Prepare do
  @moduledoc """
  Handles the preparation phase of rename operations.

  The preparation phase determines:
  - Whether the entity at the cursor can be renamed
  - What the current name is
  - What range should be replaced
  """
  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeMod.Rename
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  require Logger

  @renaming_modules [Rename.Module]

  @doc """
  Prepares a rename operation at the given position.

  Returns `{:ok, module_name_string, range}` if the entity can be renamed,
  or an appropriate error.
  """
  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, String.t(), Range.t()} | {:ok, nil} | {:error, term()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, {:module, _module}, range} ->
        {:ok, Document.fragment(analysis.document, range.start, range.end), range}

      {:error, {:unsupported_location, _}} ->
        {:ok, nil}

      {:error, {:unsupported_entity, _entity_type}} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Resolves the entity at the given position for renaming.

  Returns `{:ok, {entity_type, entity}, range}` if the entity can be renamed,
  or an error tuple.
  """
  @spec resolve(Analysis.t(), Position.t()) ::
          {:ok, {atom(), atom()}, Range.t()} | {:error, tuple() | atom()}
  def resolve(%Analysis{} = analysis, %Position{} = position) do
    prepare_result =
      Enum.find_value(@renaming_modules, fn module ->
        if module.recognizes?(analysis, position) do
          module.prepare(analysis, position)
        end
      end)

    prepare_result || handle_unsupported_entity(analysis, position)
  end

  defp handle_unsupported_entity(analysis, position) do
    with {:ok, other, _range} <- Entity.resolve(analysis, position) do
      Logger.info("Unsupported entity for renaming: #{inspect(other)}")
      {:error, {:unsupported_entity, elem(other, 0)}}
    end
  end
end
