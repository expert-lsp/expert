defmodule Expert.Integrations.SemanticMetadata.Completion do
  @moduledoc false

  alias Expert.CodeIntelligence.BeamDocs
  alias Expert.Integrations.SemanticMetadata
  alias Expert.Integrations.SemanticMetadata.Completion.Result
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Completion.Candidate.ArgumentNames
  alias Forge.Formats

  @calls %{
    callback: {Candidate.Callback, :callback},
    function: {Candidate.Function, :function},
    macro: {Candidate.Macro, :macro},
    typespec: {Candidate.Typespec, :type}
  }

  def complete(%Env{} = env) do
    with false <- Env.in_context?(env, :comment),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, [_ | _] = documents} <- SemanticMetadata.documents_at(env, cursor_path),
         {:ok, scope, env} <- CursorScope.at(env, cursor_path, documents) do
      scope
      |> complete_scope(cursor_path, env)
      |> Map.put(:env, env)
    else
      _ -> %Result{env: env}
    end
  end

  defp complete_scope(scope, cursor_path, env) do
    case Handlers.complete(scope, cursor_path, env) do
      %Result{mode: :delegate} = delegation -> delegation
      provided -> merge(static_result(scope, env), provided)
    end
  end

  defp static_result(scope, %Env{} = env) do
    if Env.in_context?(env, :string) or
         match?({:dot, _, _}, Code.Fragment.cursor_context(env.prefix)) do
      %Result{}
    else
      existing_keywords = CursorScope.existing_keywords(scope)
      hint = env |> hint() |> String.downcase()

      entries =
        for entry <- scope.entries,
            not existing_keyword?(entry, existing_keywords),
            entry |> entry_name() |> String.downcase() |> String.starts_with?(hint),
            do: entry

      result(items(entries, env.project))
    end
  end

  defp existing_keyword?(%{kind: :keyword, name: name}, existing),
    do: Atom.to_string(name) in existing

  defp existing_keyword?(_entry, _existing), do: false

  defp result([]), do: %Result{}
  defp result(candidates), do: %Result{mode: :augment, candidates: candidates, incomplete?: true}

  defp merge(%Result{mode: :ignore}, %Result{mode: :augment, candidates: []}), do: %Result{}

  defp merge(%Result{mode: :ignore}, %Result{} = provided), do: provided

  defp merge(%Result{candidates: static}, %Result{} = provided),
    do: %Result{provided | candidates: static ++ provided.candidates, incomplete?: true}

  def items(entries, project) do
    docs = module_docs(entries, project)
    for entry <- entries, do: candidate(entry, entry_documentation(entry, docs), docs)
  end

  def documentation(entry, project), do: entry_documentation(entry, module_docs([entry], project))

  def entry_name(%{mfa: {_module, name, _arity}}), do: Atom.to_string(name)
  def entry_name(%{kind: :keyword, name: name}), do: Atom.to_string(name)
  def entry_name(%{kind: :literal, value: value}) when is_atom(value), do: Atom.to_string(value)
  def entry_name(%{kind: :literal, value: value}), do: inspect(value)

  def hint(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {context, chars} when context in [:alias, :local_or_var, :local_call, :unquoted_atom] ->
        to_string(chars)

      {context, _base, chars} when context in [:alias, :dot] ->
        to_string(chars)

      _context ->
        ""
    end
  end

  defp candidate(%{kind: kind, mfa: {module, name, arity}}, documentation, docs)
       when is_map_key(@calls, kind) do
    {candidate_module, type} = Map.fetch!(@calls, kind)
    {signatures, _docs, metadata} = Map.get(docs[module], {type, name, arity}, {[], %{}, %{}})

    candidate_module.new(%{
      args_list: ArgumentNames.from_signatures(signatures, arity),
      arity: arity,
      doc: documentation,
      metadata: metadata,
      name: Atom.to_string(name),
      origin: Formats.module(module),
      summary: documentation,
      type: type,
      visibility: :public
    })
  end

  defp candidate(%{kind: kind, mfa: {module, name, arity}}, documentation, _docs) do
    %Candidate.Generic{
      label: "#{name}/#{arity}",
      filter_text: Atom.to_string(name),
      snippet: call_snippet(name, arity),
      detail: Formats.mfa(module, name, arity),
      documentation: documentation,
      kind: kind
    }
  end

  defp candidate(%{kind: :keyword, name: name}, documentation, _docs) do
    %Candidate.Generic{
      label: Atom.to_string(name),
      filter_text: Atom.to_string(name),
      snippet: "#{name}: $0",
      detail: "Keyword",
      documentation: documentation,
      kind: :field
    }
  end

  defp candidate(%{kind: :literal, value: value} = entry, documentation, _docs) do
    %Candidate.Generic{
      label: inspect(value),
      filter_text: entry_name(entry),
      insert_text: inspect(value),
      detail: "Value",
      documentation: documentation,
      kind: :enum_member
    }
  end

  defp call_snippet(name, arity) do
    arguments =
      arity
      |> ArgumentNames.placeholders()
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {argument, index} -> "${#{index}:#{argument}}" end)

    "#{name}(#{arguments})"
  end

  defp module_docs(entries, project) do
    call_modules =
      for %{kind: kind, mfa: {module, _name, _arity}} when is_map_key(@calls, kind) <- entries,
          do: module

    doc_modules = for %{doc: {module, _kind, _name, _arity}} <- entries, do: module

    for module <- Enum.uniq(call_modules ++ doc_modules),
        into: %{},
        do: {module, BeamDocs.fetch(project, module)}
  end

  defp entry_documentation(%{doc: doc}, _docs) when is_binary(doc), do: doc

  defp entry_documentation(%{doc: {module, kind, name, arity}}, docs) do
    case docs[module][{kind, name, arity}] do
      {_signatures, %{"en" => documentation}, _metadata} -> documentation
      _docs -> ""
    end
  end

  defp entry_documentation(_entry, _docs), do: ""
end
