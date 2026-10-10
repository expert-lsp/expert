defmodule Expert.Integrations.SemanticMetadata.Common do
  @moduledoc false

  alias Expert.CodeIntelligence.BeamDocs
  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Integrations.SemanticMetadata.Sigil
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Completion.Candidate.ArgumentNames
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  @blocks Map.new(~w(do else after rescue catch)a, &{Atom.to_string(&1), &1})

  @calls %{
    callback: {Candidate.Callback, :callback},
    function: {Candidate.Function, :function},
    macro: {Candidate.Macro, :macro},
    typespec: {Candidate.Typespec, :type}
  }

  def records(project) do
    case Store.prefix(project, Indexer.subject_prefix(), type: :metadata, subtype: :integration) do
      {:ok, entries} -> for %Entry{metadata: %{payload: document}} <- entries, do: document
      _error -> []
    end
  end

  def with_cursor_env(%Env{} = env) do
    cursor_env = EngineApi.cursor_env(env.project, env.document, env.position)
    %Env{env | analysis: %{env.analysis | cursor_env: cursor_env}}
  end

  def scope_at(%Env{} = env, cursor_path, documents) do
    with :error <- language_scope(documents, env),
         :error <- sigil_scope(documents, env) do
      scope =
        for descriptor <- call_descriptors(cursor_path),
            descriptor = Map.put(descriptor, :arity, call_arity(descriptor, env.analysis)),
            document <- documents,
            %{mfa: _mfa} = context <- document.contexts,
            reduce: %CursorScope{} do
          scope -> apply_call_context(scope, document, descriptor, context, env)
        end

      if scope.id == nil, do: :error, else: {:ok, scope}
    end
  end

  defp language_scope(documents, %Env{} = env) do
    language_id = env.document.language_id

    case find_context(documents, &match?(%{language_id: ^language_id}, &1)) do
      {document, context} -> {:ok, enter(%CursorScope{position: :document}, document, context)}
      nil -> :error
    end
  end

  defp sigil_scope(documents, %Env{} = env) do
    with true <- Enum.any?(documents, &Enum.any?(&1.contexts, fn context -> context[:sigil] end)),
         {:ok, sigil} <- Sigil.at(env.analysis, env.position),
         {document, context} <- find_context(documents, &(&1[:sigil] == sigil.name)) do
      {:ok, enter(%CursorScope{position: :sigil, sigil: sigil}, document, context)}
    else
      _ -> :error
    end
  end

  defp find_context(documents, fun) do
    Enum.find_value(documents, fn document ->
      case Enum.find(document.contexts, fun) do
        nil -> nil
        context -> {document, context}
      end
    end)
  end

  defp apply_call_context(scope, document, descriptor, context, env) do
    if context_position(context) == descriptor.position and
         target?(descriptor, context.mfa, scope.entries, env) do
      %CursorScope{
        argument: descriptor.argument,
        arguments: descriptor.arguments,
        call: descriptor.container,
        position: descriptor.position,
        target: context.mfa
      }
      |> enter(document, context)
      |> follow_value_scopes(descriptor.argument)
    else
      scope
    end
  end

  defp enter(%CursorScope{} = scope, document, %{scope: id}) do
    %{entries: entries} = selected = Map.fetch!(document.scopes, id)
    %{scope | document: document, id: id, entries: entries, data: Map.get(selected, :data, [])}
  end

  defp follow_value_scopes(scope, nil), do: scope

  defp follow_value_scopes(scope, argument) do
    case Ast.keyword_path_at_cursor(argument) do
      {:ok, path} -> Enum.reduce_while(path, scope, &follow_keyword/2)
      :error -> scope
    end
  end

  defp follow_keyword(key, scope) do
    case Enum.find(scope.entries, &(&1.kind == :keyword and Atom.to_string(&1.name) == key)) do
      %{value_scope: id} -> {:cont, enter(scope, scope.document, %{scope: id})}
      _entry -> {:halt, %CursorScope{}}
    end
  end

  def items(entries, project) do
    docs = module_docs(entries, project)
    for entry <- entries, do: candidate(entry, entry_documentation(entry, docs), docs)
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

  def documentation(entry, project), do: entry_documentation(entry, module_docs([entry], project))

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

  def entry_name(%{mfa: {_module, name, _arity}}), do: Atom.to_string(name)
  def entry_name(%{kind: :keyword, name: name}), do: Atom.to_string(name)
  def entry_name(%{kind: :literal, value: value}) when is_atom(value), do: Atom.to_string(value)
  def entry_name(%{kind: :literal, value: value}), do: inspect(value)

  def identifier_at(%Env{} = env) do
    with {:ok,
          %{begin: {begin_line, begin_column}, context: context, end: {end_line, end_column}}} <-
           Ast.surround_context(env.analysis, env.position),
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
       when context in [:keyword, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp surround_identifier({:dot, _base, chars}), do: to_string(chars)
  defp surround_identifier(_context), do: nil

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

  def existing_keywords(%CursorScope{argument: argument}) when argument != nil do
    with {:ok, path} <- Ast.keyword_path_at_cursor(argument),
         keywords when is_list(keywords) <- keywords_at(argument, Enum.drop(path, -1)) do
      for {key, _value} <- keywords, name = Ast.keyword_key(key), name != nil, do: name
    else
      _ -> []
    end
  end

  def existing_keywords(%CursorScope{}), do: []

  defp call_descriptors(cursor_path) do
    path = Enum.reverse(cursor_path)

    for {parent, node} <- Enum.zip([nil | path], path),
        {:ok, arguments} <- [call_arguments(node)],
        {container, arguments} = piped(parent, node, arguments),
        {:ok, position, argument} <- [cursor_position(arguments)] do
      %{
        call: node,
        container: container,
        arguments: arguments,
        position: position,
        argument: argument
      }
    end
  end

  defp call_arguments({{:., _, [_module, name]}, _, arguments})
       when is_atom(name) and is_list(arguments),
       do: {:ok, arguments}

  defp call_arguments({name, _, arguments})
       when is_atom(name) and is_list(arguments),
       do: {:ok, arguments}

  defp call_arguments(_node), do: :error

  defp piped({:|>, _, [left, node]} = pipe, node, arguments), do: {pipe, [left | arguments]}
  defp piped(_parent, node, arguments), do: {node, arguments}

  defp cursor_position(arguments) do
    arguments
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {argument, index} ->
      if Ast.contains_cursor?(argument) do
        case Ast.keyword_path_at_cursor(argument) do
          {:ok, [block | _]} when is_map_key(@blocks, block) ->
            {:ok, {:block, Map.fetch!(@blocks, block)}, nil}

          _path ->
            {:ok, {:argument, index}, argument}
        end
      end
    end)
  end

  # The cursor path stops at the cursor, so its calls miss the arguments after
  # the cursor. To count those, this finds the same call in the AST of the
  # document. When the document can't parse there, as with an unclosed call,
  # it counts the arguments up to the cursor.
  defp call_arity(%{call: call, container: container, arguments: arguments}, analysis) do
    piped = if container == call, do: 0, else: 1

    case document_arguments(analysis.ast, call) do
      {:ok, count} -> count + piped
      :error -> length(arguments)
    end
  end

  defp document_arguments(nil, _call), do: :error

  defp document_arguments(ast, {form, meta, _arguments}) do
    location = {meta[:line], meta[:column]}
    name = call_name(form)

    {_ast, count} =
      Macro.prewalk(ast, :error, fn
        {node_form, node_meta, arguments} = node, :error
        when is_list(node_meta) and is_list(arguments) ->
          if {node_meta[:line], node_meta[:column]} == location and call_name(node_form) == name,
            do: {node, {:ok, length(arguments)}},
            else: {node, :error}

        node, count ->
          {node, count}
      end)

    count
  end

  defp call_name({:., _, [_module, name]}), do: name
  defp call_name(name), do: name

  defp target?(descriptor, {_module, _name, arity} = mfa, entries, env) do
    descriptor.arity == arity and
      (target_identity?(descriptor.call, mfa, env) or
         call_entry?(descriptor.call, mfa, entries))
  end

  defp target_identity?(
         {{:., _, [module_ast, name]}, _, _arguments},
         {module, name, _arity},
         env
       ),
       do: expand_module(module_ast, env) == {:ok, module}

  defp target_identity?({name, _, arguments}, {_module, name, _arity} = mfa, env)
       when is_list(arguments),
       do: local_target?(mfa, env)

  defp target_identity?(_call, _mfa, _env), do: false

  # Matches a local call to an entry of the scope of an outer call. In
  # `from(User, where: coalesce(name, |))`, `coalesce/2` is an entry of the
  # `where` scope. `from` reads that call itself, so the module doesn't need to
  # import `coalesce/2`.
  defp call_entry?({name, _, arguments}, {_module, name, _arity} = mfa, entries)
       when is_list(arguments),
       do: Enum.any?(entries, &match?(%{mfa: ^mfa}, &1))

  defp call_entry?(_call, _mfa, _entries), do: false

  defp local_target?({module, name, arity}, %Env{} = env) do
    module_exports = &ModuleRegistry.module_exports(env.project, &1)

    Analyzer.current_module(env.analysis, env.position) == {:ok, module} or
      Analyzer.import_module_for(env.analysis, env.position, name, arity, module_exports) ==
        {:ok, module}
  end

  defp expand_module({:__aliases__, _, segments}, env),
    do: Analyzer.expand_alias(segments, env.analysis, env.position)

  defp expand_module({:__block__, _, [value]}, env), do: expand_module(value, env)
  defp expand_module(module, _env) when is_atom(module), do: {:ok, module}
  defp expand_module(_module, _env), do: :error

  defp keywords_at({:__block__, _, [value]}, path), do: keywords_at(value, path)
  defp keywords_at(value, []), do: value

  defp keywords_at(keywords, [key | path]) when is_list(keywords) do
    Enum.find_value(keywords, fn
      {candidate, value} -> if Ast.keyword_key(candidate) == key, do: keywords_at(value, path)
      _value -> nil
    end)
  end

  defp keywords_at(_value, _path), do: nil

  defp context_position(%{argument: argument}), do: {:argument, argument}
  defp context_position(%{block: block}), do: {:block, block}
end
