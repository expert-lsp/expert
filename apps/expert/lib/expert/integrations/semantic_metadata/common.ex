defmodule Expert.Integrations.SemanticMetadata.Common do
  @moduledoc false

  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  @provider "semantic"
  @block_keys [:do, :else, :after, :rescue, :catch]
  @local_call_exclusions [
    :__block__,
    :__cursor__,
    :__aliases__,
    :{},
    :%{},
    :<<>>,
    :->,
    :fn,
    :|>,
    :def,
    :defp,
    :defmacro,
    :defmodule,
    :alias,
    :import,
    :require,
    :quote,
    :unquote,
    :unquote_splicing
  ]

  def records(project) do
    case Store.prefix(
           project,
           Entry.integration_subject_prefix(@provider, :dsl),
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn
          %Entry{metadata: %{payload: %{kind: :dsl} = document}} -> [document]
          _entry -> []
        end)

      _error ->
        []
    end
  end

  def scope_at(%Env{} = env, cursor_path) do
    documents = records(env.project)

    cursor_path
    |> call_descriptors()
    |> Enum.reduce(%{candidates: [], data: [], matched?: false}, fn descriptor, state ->
      apply_contexts(state, documents, descriptor, env)
    end)
    |> case do
      %{matched?: true} = state -> {:ok, state}
      _state -> :error
    end
  end

  @typed_candidates %{
    callback: Candidate.Callback,
    function: Candidate.Function,
    macro: Candidate.Macro,
    typespec: Candidate.Typespec
  }

  def item(%{mfa: mfa} = candidate, project) do
    documentation = documentation(candidate, project)

    case Map.fetch(@typed_candidates, candidate.kind) do
      {:ok, candidate_module} ->
        typed_candidate(candidate_module, mfa, documentation)

      :error ->
        generic_callable(candidate, mfa, documentation)
    end
  end

  def item(candidate, project) do
    documentation = documentation(candidate, project)

    case candidate do
      %{kind: :keyword, name: name} ->
        %Candidate.Generic{
          label: name,
          filter_text: name,
          snippet: "#{name}: $0",
          detail: "Keyword",
          documentation: documentation,
          priority: :contextual,
          kind: :field
        }

      %{kind: :literal, value: value} ->
        label = inspect(value)

        %Candidate.Generic{
          label: label,
          filter_text: String.trim_leading(label, ":"),
          insert_text: label,
          detail: "Value",
          documentation: documentation,
          priority: :contextual,
          kind: :enum_member
        }
    end
  end

  defp typed_candidate(candidate_module, mfa, documentation) do
    fields = %{
      argument_names: argument_names(mfa.arity),
      arity: mfa.arity,
      metadata: %{},
      name: mfa.name,
      origin: String.trim_leading(mfa.module, "Elixir."),
      type: candidate_type(candidate_module)
    }

    fields =
      case candidate_module do
        Candidate.Typespec -> Map.put(fields, :doc, documentation)
        _candidate_module -> Map.put(fields, :summary, documentation)
      end

    fields =
      if candidate_module in [Candidate.Function, Candidate.Macro] do
        Map.put(fields, :visibility, :public)
      else
        fields
      end

    struct(candidate_module, fields)
  end

  defp candidate_type(Candidate.Callback), do: :callback
  defp candidate_type(Candidate.Function), do: :function
  defp candidate_type(Candidate.Macro), do: :macro
  defp candidate_type(Candidate.Typespec), do: :type

  defp generic_callable(candidate, mfa, documentation) do
    %Candidate.Generic{
      label: "#{mfa.name}/#{mfa.arity}",
      filter_text: mfa.name,
      snippet: callable_snippet(mfa),
      detail: format_mfa(mfa),
      documentation: documentation,
      priority: :contextual,
      kind: candidate.kind
    }
  end

  defp argument_names(0), do: []
  defp argument_names(arity), do: Enum.map(1..arity, &"arg#{&1}")

  def documentation(%{doc: doc}, _project) when is_binary(doc), do: doc

  def documentation(%{doc: reference}, project) when is_map(reference) do
    eep48_documentation(project, reference)
  end

  def documentation(_candidate, _project), do: ""

  def candidate_name(%{mfa: mfa}), do: mfa.name
  def candidate_name(%{kind: :keyword, name: name}), do: name
  def candidate_name(%{kind: :literal, value: value}), do: inspect(value)

  def hint(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {:alias, chars} -> to_string(chars)
      {:alias, _base, chars} -> to_string(chars)
      {:local_or_var, chars} -> to_string(chars)
      {:local_call, chars} -> to_string(chars)
      {:unquoted_atom, chars} -> to_string(chars)
      {:dot, _base, chars} -> to_string(chars)
      _context -> ""
    end
  end

  def matches?(_candidate, ""), do: true

  def matches?(candidate, hint) do
    name = candidate_name(candidate)

    String.starts_with?(String.downcase(name), String.downcase(hint)) or
      String.starts_with?(String.downcase(String.trim_leading(name, ":")), String.downcase(hint))
  end

  def existing_keywords(%{argument: argument}) do
    case Ast.keyword_path_at_cursor(argument) do
      {:ok, path} -> keywords_at_path(argument, Enum.drop(path, -1))
      :error -> []
    end
  end

  def existing_keywords(_state), do: []

  defp apply_contexts(state, documents, descriptor, env) do
    Enum.reduce(documents, state, fn document, current ->
      Enum.reduce(document.contexts, current, fn context, current ->
        if context_position(context) == descriptor.position and
             target?(descriptor, context.mfa, current.candidates, env) do
          current
          |> Map.put(:call, descriptor.container)
          |> Map.put(:target, context.mfa)
          |> Map.put(:position, descriptor.position)
          |> apply_scope(document, context.scope)
          |> follow_value_scopes(document, descriptor.argument)
          |> Map.put(:argument, descriptor.argument)
          |> Map.put(:matched?, true)
        else
          current
        end
      end)
    end)
  end

  defp follow_value_scopes(state, _document, nil), do: state

  defp follow_value_scopes(state, document, argument) do
    case Ast.keyword_path_at_cursor(argument) do
      {:ok, path} -> Enum.reduce_while(path, state, &follow_keyword(&1, &2, document))
      :error -> state
    end
  end

  defp follow_keyword(key, state, document) when is_binary(key) do
    case Enum.find(state.candidates, fn candidate ->
           candidate.document == document and candidate.value.kind == :keyword and
             candidate.value.name == key
         end) do
      %{value: %{value_scope: scope}} ->
        {:cont, apply_scope(state, document, scope)}

      _candidate ->
        {:halt, state}
    end
  end

  defp follow_keyword(_key, state, _document), do: {:halt, state}

  defp apply_scope(state, document, scope_id) do
    scope = Map.fetch!(document.scopes, scope_id)
    candidates = Enum.map(scope.entries, &%{document: document, value: &1})

    %{state | candidates: candidates, data: scope.data}
    |> Map.put(:scope, scope_id)
  end

  defp call_descriptors(cursor_path) do
    cursor_path
    |> Enum.reverse()
    |> Enum.reduce({[], []}, fn node, {descriptors, skipped} ->
      cond do
        Enum.any?(skipped, &(&1 == node)) ->
          {descriptors, skipped}

        match?({:|>, _, [_left, _call]}, node) ->
          {:|>, _, [left, call]} = node

          case call_parts(call) do
            {:ok, call, arguments} ->
              descriptor = descriptor(call, [left | arguments], node, 1)
              {append_descriptor(descriptors, descriptor), [call | skipped]}

            :error ->
              {descriptors, skipped}
          end

        true ->
          case call_parts(node) do
            {:ok, call, arguments} ->
              {append_descriptor(descriptors, descriptor(call, arguments, node, 0)), skipped}

            :error ->
              {descriptors, skipped}
          end
      end
    end)
    |> elem(0)
  end

  defp append_descriptor(descriptors, nil), do: descriptors
  defp append_descriptor(descriptors, descriptor), do: descriptors ++ [descriptor]

  defp descriptor(call, arguments, container, pipe_offset) do
    with true <- Ast.contains_cursor?(container),
         {:ok, position, argument} <- cursor_position(arguments) do
      %{
        call: call,
        container: container,
        arguments: arguments,
        position: position,
        argument: argument,
        pipe_offset: pipe_offset
      }
    else
      _ -> nil
    end
  end

  defp cursor_position(arguments) do
    case block_position(arguments) do
      {:ok, _position, _argument} = result -> result
      :error -> argument_position(arguments)
    end
  end

  defp block_position(arguments) do
    Enum.find_value(arguments, :error, fn argument ->
      Enum.find_value(@block_keys, fn key ->
        with {:ok, value} <- keyword_value(argument, key),
             true <- Ast.contains_cursor?(value) do
          {:ok, {:block, key}, nil}
        else
          _ -> nil
        end
      end)
    end)
  end

  defp argument_position(arguments) do
    arguments
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {argument, index} ->
      if Ast.contains_cursor?(argument), do: {:ok, {:argument, index}, argument}
    end)
  end

  defp keyword_value({:__block__, _, [value]}, key), do: keyword_value(value, key)

  defp keyword_value(values, key) when is_list(values) do
    Enum.find_value(values, :error, fn
      {candidate_key, value} -> if option_key(candidate_key) == key, do: {:ok, value}
      _value -> nil
    end)
  end

  defp keyword_value(_values, _key), do: :error

  defp call_parts({{:., _, [_module, name]}, _, arguments} = call)
       when is_atom(name) and is_list(arguments),
       do: {:ok, call, arguments}

  defp call_parts({name, _, arguments} = call)
       when is_atom(name) and is_list(arguments) and name not in @local_call_exclusions,
       do: {:ok, call, arguments}

  defp call_parts(_call), do: :error

  defp target?(descriptor, target, active_candidates, env) do
    length(descriptor.arguments) == target.arity and
      (target_identity?(descriptor.call, target, env) or
         active_callable?(descriptor.call, target, active_candidates))
  end

  defp target_identity?({{:., _, [module_ast, name]}, _, _arguments}, target, env) do
    to_string(name) == target.name and expand_module(module_ast, env) == {:ok, target.module}
  end

  defp target_identity?({name, _, arguments}, target, env)
       when is_atom(name) and is_list(arguments),
       do: to_string(name) == target.name and local_target?(target, env)

  defp target_identity?(_call, _target, _env), do: false

  defp active_callable?({name, _, arguments}, target, active_candidates)
       when is_atom(name) and is_list(arguments) do
    to_string(name) == target.name and
      Enum.any?(active_candidates, fn
        %{value: %{mfa: ^target}} -> true
        _candidate -> false
      end)
  end

  defp active_callable?(_call, _target, _active_candidates), do: false

  defp local_target?(target, %Env{} = env) do
    current_module =
      case Analyzer.current_module(env.analysis, env.position) do
        {:ok, module} -> Atom.to_string(module)
        :error -> nil
      end

    current_module == target.module or imported_target?(target, env)
  end

  defp imported_target?(target, %Env{} = env) do
    name = String.to_existing_atom(target.name)

    module_exports = &module_exports(env.project, &1)

    case Analyzer.import_module_for(
           env.analysis,
           env.position,
           name,
           target.arity,
           module_exports
         ) do
      {:ok, module} ->
        Atom.to_string(module) == target.module

      _error ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp module_exports(project, module) do
    case :ets.whereis(ModuleRegistry.name(project)) do
      :undefined -> :error
      _table -> ModuleRegistry.module_exports(project, module)
    end
  end

  defp expand_module({:__aliases__, _, segments}, env) do
    case Analyzer.expand_alias(segments, env.analysis, env.position) do
      {:ok, module} -> {:ok, Atom.to_string(module)}
      :error -> :error
    end
  end

  defp expand_module({:__block__, _, [value]}, env), do: expand_module(value, env)
  defp expand_module(module, _env) when is_atom(module), do: {:ok, Atom.to_string(module)}
  defp expand_module(_module, _env), do: :error

  defp keywords_at_path(argument, path) do
    case descend_keywords(argument, path) do
      values when is_list(values) ->
        Enum.flat_map(values, fn
          {key, _value} ->
            case option_key(key) do
              nil -> []
              key -> [Atom.to_string(key)]
            end

          _value ->
            []
        end)

      _value ->
        []
    end
  end

  defp descend_keywords({:__block__, _, [value]}, path), do: descend_keywords(value, path)
  defp descend_keywords(value, []), do: value

  defp descend_keywords(values, [key | path]) when is_list(values) do
    Enum.find_value(values, fn
      {candidate_key, value} ->
        if to_string(option_key(candidate_key)) == key, do: descend_keywords(value, path)

      _value ->
        nil
    end)
  end

  defp descend_keywords(_value, _path), do: nil

  defp option_key(key) when is_atom(key), do: key
  defp option_key({:__block__, _, [key]}) when is_atom(key), do: key
  defp option_key(_key), do: nil

  defp callable_snippet(%{name: name, arity: 0}), do: "#{name}()"

  defp callable_snippet(%{name: name, arity: arity}) do
    arguments = Enum.map_join(1..arity, ", ", &"${#{&1}:arg#{&1}}")
    "#{name}(#{arguments})"
  end

  defp context_position(%{argument: argument}), do: {:argument, argument}
  defp context_position(%{block: block}), do: {:block, block}

  defp format_mfa(%{module: "Elixir." <> module, name: name, arity: arity}),
    do: "#{module}.#{name}/#{arity}"

  defp format_mfa(%{module: module, name: name, arity: arity}),
    do: "#{module}.#{name}/#{arity}"

  defp eep48_documentation(project, reference) do
    with {:ok, module} <- existing_module(reference.module),
         path when is_binary(path) <- ModuleRegistry.beam_path(project, module),
         {:ok, {_module, [{~c"Docs", binary}]}} <-
           :beam_lib.chunks(String.to_charlist(path), [~c"Docs"]),
         {:docs_v1, _, _, _, _, _, entries} <- :erlang.binary_to_term(binary),
         entry when not is_nil(entry) <-
           Enum.find(entries, &documentation_entry?(&1, reference)) do
      documentation = entry_documentation(entry)
      documentation
    else
      _error -> ""
    end
  rescue
    ArgumentError -> ""
  end

  defp existing_module("Elixir." <> _rest = module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    ArgumentError -> :error
  end

  defp existing_module(module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    ArgumentError -> :error
  end

  defp documentation_entry?({{kind, name, arity}, _, _, _, _}, reference) do
    kind == reference.kind and Atom.to_string(name) == reference.name and arity == reference.arity
  end

  defp documentation_entry?(_entry, _reference), do: false

  defp entry_documentation({_identity, _anno, _signatures, %{} = docs, _metadata}) do
    Map.get(docs, "en", "")
  end

  defp entry_documentation(_entry), do: ""
end
