defmodule Expert.Integrations.SemanticMetadata.References do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Entity
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Expert.Search.Store
  alias Expert.Search.Subject
  alias Forge.Search.Indexer.Entry

  @impl Expert.Integrations
  def references(project, entity) do
    for document <- Common.records(project),
        [_ | _] = handlers <- [Handlers.document_handlers([document], :references)],
        [_ | _] = files <- [context_calls(project, document)],
        %{} = entity <- [Entity.to_spec(project, entity)],
        location <- Handlers.references(handlers, project, entity, files),
        do: location
  end

  defp context_calls(project, document) do
    targets =
      for %{mfa: {module, function, arity} = mfa} <- document.contexts,
          into: %{},
          do: {Subject.mfa(module, function, arity), mfa}

    case Store.exact_many(project, Map.keys(targets), subtype: :reference) do
      {:ok, entries} ->
        entries
        |> Enum.group_by(& &1.path, &call(&1, targets))
        |> Enum.map(fn {path, calls} ->
          %{path: path, calls: calls |> Enum.uniq() |> Enum.sort()}
        end)
        |> Enum.sort_by(& &1.path)

      _error ->
        []
    end
  end

  defp call(%Entry{range: range, subject: subject}, targets) do
    %{
      position: %{line: range.start.line, character: range.start.character},
      target: Map.fetch!(targets, subject)
    }
  end
end
