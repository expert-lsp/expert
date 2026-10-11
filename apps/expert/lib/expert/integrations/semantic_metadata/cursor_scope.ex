defmodule Expert.Integrations.SemanticMetadata.CursorScope do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Sigil
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Ast
  alias Forge.Ast.Env

  @blocks Map.new(~w(do else after rescue catch)a, &{Atom.to_string(&1), &1})

  @type t :: %__MODULE__{
          argument: Macro.t() | nil,
          arguments: [Macro.t()],
          call: Macro.t() | nil,
          data: keyword(),
          document: map() | nil,
          entries: [map()],
          id: term(),
          position: {:argument, non_neg_integer()} | {:block, atom()} | :document | :sigil | nil,
          sigil: map() | nil,
          target: mfa() | nil
        }

  defstruct [
    :argument,
    :call,
    :document,
    :id,
    :position,
    :sigil,
    :target,
    arguments: [],
    data: [],
    entries: []
  ]

  def at(%Env{} = env, cursor_path, documents) do
    with :error <- language_scope(documents, env),
         :error <- sigil_scope(documents, env) do
      call_scope(documents, cursor_path, env)
    end
  end

  def existing_keywords(%__MODULE__{argument: argument}) when argument != nil do
    with {:ok, path} <- Ast.keyword_path_at_cursor(argument),
         keywords when is_list(keywords) <- keywords_at(argument, Enum.drop(path, -1)) do
      for {key, _value} <- keywords, name = Ast.keyword_key(key), name != nil, do: name
    else
      _ -> []
    end
  end

  def existing_keywords(%__MODULE__{}), do: []

  def call_names(cursor_path) do
    for %{call: {form, _, _}} <- call_descriptors(cursor_path), uniq: true, do: call_name(form)
  end

  defp language_scope(documents, %Env{} = env) do
    language_id = env.document.language_id

    case find_context(documents, &match?(%{language_id: ^language_id}, &1)) do
      {document, context} ->
        {:ok, enter(%__MODULE__{position: :document}, document, context), env}

      nil ->
        :error
    end
  end

  defp sigil_scope(documents, %Env{} = env) do
    with true <- Enum.any?(documents, &Enum.any?(&1.contexts, fn context -> context[:sigil] end)),
         {:ok, sigil} <- Sigil.at(env.analysis, env.position),
         {document, context} <- find_context(documents, &(&1[:sigil] == sigil.name)) do
      env = with_cursor_env(env)
      {:ok, enter(%__MODULE__{position: :sigil, sigil: sigil}, document, context), env}
    else
      _ -> :error
    end
  end

  defp call_scope(documents, cursor_path, %Env{} = env) do
    contexts =
      for document <- documents,
          %{mfa: {_module, name, _arity}} = context <- document.contexts,
          do: {name, document, context}

    candidates =
      for %{call: {form, _, _}} = descriptor <- call_descriptors(cursor_path),
          name = call_name(form),
          matches =
            for(
              {^name, document, context} <- contexts,
              context_position(context) == descriptor.position,
              do: {document, context}
            ),
          matches != [],
          do: {descriptor, matches}

    case candidates do
      [_ | _] ->
        env = with_cursor_env(env)
        arities = call_arities(env.analysis.ast)

        scope =
          for {descriptor, matches} <- candidates,
              descriptor = Map.put(descriptor, :arity, call_arity(descriptor, arities)),
              {document, context} <- matches,
              reduce: %__MODULE__{} do
            scope -> apply_call_context(scope, document, descriptor, context, env)
          end

        if scope.id == nil, do: :error, else: {:ok, scope, env}

      _ ->
        :error
    end
  end

  defp with_cursor_env(%Env{} = env) do
    cursor_env = EngineApi.cursor_env(env.project, env.document, env.position)
    %Env{env | analysis: %{env.analysis | cursor_env: cursor_env}}
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
    if target?(descriptor, context.mfa, scope.entries, env) do
      %__MODULE__{
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

  defp enter(%__MODULE__{} = scope, document, %{scope: id}) do
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
      _entry -> {:halt, %__MODULE__{}}
    end
  end

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
  defp call_arities(nil), do: %{}

  defp call_arities(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.reduce(%{}, fn
      {form, meta, arguments}, arities when is_list(meta) and is_list(arguments) ->
        Map.put(arities, {{meta[:line], meta[:column]}, call_name(form)}, length(arguments))

      _node, arities ->
        arities
    end)
  end

  defp call_arity(
         %{call: {form, meta, _}, container: container, arguments: arguments} = descriptor,
         arities
       ) do
    piped = if container == descriptor.call, do: 0, else: 1

    case Map.fetch(arities, {{meta[:line], meta[:column]}, call_name(form)}) do
      {:ok, count} -> count + piped
      :error -> length(arguments)
    end
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
