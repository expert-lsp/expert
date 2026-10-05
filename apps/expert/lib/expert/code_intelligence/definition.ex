defmodule Expert.CodeIntelligence.Definition do
  @moduledoc "Resolves definitions from Manager-owned search entries."

  alias Expert.CodeIntelligence.Variable
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @spec definition(Project.t(), Document.t(), Position.t()) ::
          {:ok, Location.t() | [Location.t()] | nil}
  def definition(%Project{} = project, %Document{} = document, %Position{} = position) do
    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, _, %Analysis{} = analysis} ->
        case variable_definition(analysis, position) do
          {:ok, %Entry{} = entry} ->
            {:ok, Location.new(entry.range, document.uri)}

          :error ->
            indexed_definition(project, analysis, position)
        end

      _ ->
        {:ok, nil}
    end
  end

  defp indexed_definition(project, analysis, position) do
    with {:ok, references} <- Store.entries_for_document(project, analysis, :reference),
         %Entry{} = reference <- reference_at(references, analysis, position),
         {:ok, [_ | _] = definitions} <-
           Store.exact(project, reference.subject,
             type: definition_type(reference),
             subtype: :definition
           ) do
      definitions = expand_definitions(project, definitions)

      definitions
      |> Enum.map(&Location.new(&1.range, Document.Path.ensure_uri(&1.path)))
      |> case do
        [location] -> {:ok, location}
        locations -> {:ok, locations}
      end
    else
      _ -> {:ok, nil}
    end
  end

  defp expand_definitions(project, definitions) do
    definitions
    |> Enum.flat_map(fn
      %Entry{metadata: %{via: :use, original_mfa: original_mfa}} = entry ->
        case exact_definitions(project, original_mfa) do
          [] -> [entry]
          definitions -> definitions
        end

      %Entry{type: {:function, :delegate}, metadata: %{original_mfa: original_mfa}} = entry ->
        exact_definitions(project, original_mfa) ++ [entry]

      entry ->
        [entry]
    end)
    |> Enum.uniq_by(& &1.subject)
  end

  defp exact_definitions(project, subject) do
    case Store.exact(project, subject, subtype: :definition) do
      {:ok, definitions} -> definitions
      _ -> []
    end
  end

  defp variable_definition(%Analysis{} = analysis, %Position{} = position) do
    case Ast.surround_context(analysis, position) do
      {:ok, %{context: {:local_or_var, name}}} ->
        Variable.definition(analysis, position, List.to_atom(name))

      _ ->
        :error
    end
  end

  defp reference_at(references, analysis, position) do
    function = function_at(analysis, position)

    references
    |> Enum.filter(fn
      %Entry{type: {:function, :usage}, subject: subject, range: range} ->
        Range.contains?(range, position) and
          match?({_module, ^function, _arity}, Forge.Code.parse_mfa(subject))

      %Entry{range: range} ->
        Range.contains?(range, position)
    end)
    |> Enum.min_by(&range_size/1, fn -> nil end)
  end

  defp range_size(%Entry{range: range}) do
    {range.end.line - range.start.line, range.end.character - range.start.character}
  end

  defp definition_type(%Entry{type: {kind, _}}) when kind in [:function, :macro], do: :_
  defp definition_type(%Entry{type: type}), do: type

  defp function_at(%Analysis{} = analysis, %Position{} = position) do
    case Ast.surround_context(analysis, position) do
      {:ok, %{context: {:dot, _, function}}} -> List.to_atom(function)
      {:ok, %{context: {:local_call, function}}} -> List.to_atom(function)
      {:ok, %{context: {:local_arity, function}}} -> List.to_atom(function)
      {:ok, %{context: {:local_or_var, function}}} -> local_function(analysis, position, function)
      _ -> nil
    end
  end

  defp local_function(analysis, position, function) do
    function = List.to_atom(function)

    case Variable.definition(analysis, position, function) do
      {:ok, %Entry{}} -> nil
      :error -> function
    end
  end
end
