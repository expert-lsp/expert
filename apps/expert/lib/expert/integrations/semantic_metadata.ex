defmodule Expert.Integrations.SemanticMetadata do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Completion
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Entity
  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Search.Store
  alias Expert.Search.Subject
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger

  @integration_entries [type: :metadata, subtype: :integration]

  defdelegate complete(env), to: Completion

  def records(project) do
    case indexed_records(project) do
      {:ok, records} ->
        {:ok, records}

      {:error, reason} = error ->
        Logger.warning("Could not read semantic metadata: #{inspect(reason)}")
        error
    end
  end

  def indexed_records(project) do
    with {:ok, entries} <-
           read(Store.prefix(project, Indexer.subject_prefix(), @integration_entries)),
         do: {:ok, documents(entries)}
  end

  def documents_at(%Env{project: project} = env, cursor_path) do
    lookups =
      for lookup <- [{:language, env.document.language_id} | call_lookups(cursor_path)],
          do: Indexer.lookup_subject(lookup)

    with {:ok, calls} <- read(Store.exact_many(project, lookups, @integration_entries)),
         {:ok, sigils} <-
           read(Store.prefix(project, Indexer.lookup_subject({:sigil, ""}), @integration_entries)),
         {:ok, documents} <- looked_up_documents(project, calls ++ sigils) do
      {:ok, documents}
    else
      {:error, reason} = error ->
        Logger.warning("Could not read semantic metadata: #{inspect(reason)}")
        error
    end
  end

  def cursor(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    with {:ok, env} <- Env.new(project, analysis, position),
         false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, [_ | _] = documents} <- documents_at(env, cursor_path),
         {:ok, scope, env} <- CursorScope.at(env, cursor_path, documents) do
      {identifier, range} = identifier_at(env)

      {:ok,
       %{scope: scope, cursor_path: cursor_path, env: env, identifier: identifier, range: range}}
    else
      _ -> :error
    end
  end

  def hover({:ok, cursor}) do
    Handlers.hover(cursor.scope, cursor.cursor_path, cursor.env, cursor.identifier, cursor.range) ++
      entry_hovers(cursor)
  end

  def hover(:error), do: []

  def definition({:ok, cursor}),
    do:
      Handlers.definition(
        cursor.scope,
        cursor.cursor_path,
        cursor.env,
        cursor.identifier,
        cursor.range
      )

  def definition(:error), do: []

  def resolve({:ok, cursor}),
    do:
      Handlers.resolve(
        cursor.scope,
        cursor.cursor_path,
        cursor.env,
        cursor.identifier,
        cursor.range
      )

  def resolve(:error), do: :ignore

  def signature_help({:ok, cursor}) do
    case Handlers.signature_help(cursor.scope, cursor.cursor_path, cursor.env) do
      [_ | _] = signatures -> signatures
      [] -> :ignore
    end
  end

  def signature_help(:error), do: :ignore

  def references(%Project{} = project, entity) do
    with {:ok, documents} <- records(project),
         handlers =
           for(
             document <- documents,
             [_ | _] = handlers <- [Handlers.document_handlers(document, :references)],
             do: {document, handlers}
           ),
         [_ | _] <- handlers,
         %{} = entity <- Entity.to_spec(project, entity) do
      calls = context_calls(project, Enum.map(handlers, &elem(&1, 0)))

      for {document, handlers} <- handlers,
          [_ | _] = files <- [calls_of(calls, document)],
          location <- Handlers.references(handlers, project, entity, files),
          do: location
    else
      _ -> []
    end
  end

  defp entry_hovers(%{scope: scope, identifier: identifier, env: env, range: range}) do
    with %{} = entry <- Enum.find(scope.entries, &(Completion.entry_name(&1) == identifier)),
         documentation when documentation != "" <- Completion.documentation(entry, env.project) do
      [{documentation, range}]
    else
      _error -> []
    end
  end

  defp context_calls(project, documents) do
    subjects =
      for document <- documents,
          %{mfa: {module, function, arity}} <- document.contexts,
          into: %{},
          do: {Subject.mfa(module, function, arity), {module, function, arity}}

    case Store.exact_many(project, Map.keys(subjects), subtype: :reference) do
      {:ok, entries} -> Enum.group_by(entries, &Map.fetch!(subjects, &1.subject))
      _error -> %{}
    end
  end

  defp calls_of(calls, document) do
    targets = for %{mfa: mfa} <- document.contexts, uniq: true, do: mfa

    for target <- targets,
        %Entry{path: path, range: range} <- Map.get(calls, target, []),
        reduce: %{} do
      files ->
        call = %{
          position: Positions.index_position(range.start),
          target: target
        }

        Map.update(files, path, [call], &[call | &1])
    end
    |> Enum.sort()
    |> Enum.map(fn {path, calls} -> %{path: path, calls: calls |> Enum.uniq() |> Enum.sort()} end)
  end

  defp call_lookups(cursor_path),
    do: for(name <- CursorScope.call_names(cursor_path), do: {:call, name})

  defp looked_up_documents(_project, []), do: {:ok, []}

  defp looked_up_documents(project, lookups) do
    subjects =
      for %Entry{metadata: %{payload: key}} <- lookups,
          uniq: true,
          do: Indexer.document_subject(key)

    with {:ok, entries} <- read(Store.exact_many(project, subjects, @integration_entries)),
         do: {:ok, documents(entries)}
  end

  defp documents(entries),
    do: for(%Entry{metadata: %{payload: document}} <- entries, do: document)

  # The store answers `[]` while it is not ready.
  defp read({:ok, entries}), do: {:ok, entries}
  defp read([]), do: {:ok, []}
  defp read({:error, _reason} = error), do: error

  defp identifier_at(%Env{} = env) do
    position = Positions.fragment_cursor(env.document, env.position)

    with {:ok,
          %{begin: {begin_line, begin_column}, context: context, end: {end_line, end_column}}} <-
           Ast.surround_context(env.analysis, position),
         identifier when is_binary(identifier) <- surround_identifier(context) do
      range =
        Range.new(
          Position.new(env.document, begin_line, begin_column),
          Position.new(env.document, end_line, end_column)
        )

      {identifier, range}
    else
      _ -> {nil, nil}
    end
  end

  defp surround_identifier({context, chars})
       when context in [:alias, :key, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp surround_identifier({:dot, _base, chars}), do: to_string(chars)
  defp surround_identifier(_context), do: nil
end
