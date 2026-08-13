defmodule Engine.Integrations.Spark.Completion do
  @behaviour Engine.Integrations

  alias Engine.Integrations.Spark.Common
  alias Engine.Integrations.Spark.Values
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate

  @impl Engine.Integrations
  def complete(%Env{} = env) do
    if Env.in_context?(env, :comment) or Env.in_context?(env, :string) do
      :ignore
    else
      cursor_path = Ast.cursor_path(env.analysis, env.position)

      case Common.use_context(cursor_path, env) do
        {:ok, module, argument} ->
          case Common.fetch(env.project, :dsl, module) do
            {:ok, dsl} -> completion_result(schema_items(dsl.options, argument, env), :override)
            :error -> :ignore
          end

        :error ->
          with {:ok, module, name, arity, argument_index, argument} <-
                 Common.function_context(cursor_path, env),
               key = "#{Forge.Formats.mfa(module, name, arity)}/#{argument_index}",
               {:ok, options} <- Common.fetch(env.project, :function, key) do
            completion_result(schema_items(options, argument, env), :override)
          else
            _ -> complete_dsl(env.project, env, cursor_path)
          end
      end
    end
  end

  defp completion_result({mode, candidates, transforms}, _mode),
    do: {mode, candidates, true, transforms}

  defp completion_result([], _mode), do: :ignore
  defp completion_result(candidates, mode), do: {mode, candidates, true, []}

  defp complete_dsl(project, env, cursor_path) do
    if remote_call_context?(cursor_path, env) do
      :ignore
    else
      case Common.dsl_context(project, env) do
        {:ok, dsl, use} ->
          extensions = Common.active_extensions(project, dsl, use, env)

          case dsl_items(extensions, cursor_path, env) do
            {:ok, items, mode} -> completion_result(items, mode)
            :error -> :ignore
          end

        :error ->
          :ignore
      end
    end
  end

  defp remote_call_context?(cursor_path, env) do
    match?({:dot, _, _}, Code.Fragment.cursor_context(env.prefix)) or
      Ast.remote_call?(cursor_path)
  end

  defp schema_items(options, argument, env) do
    case option_cursor(argument) do
      {:key, existing} ->
        option_items(options, env, :keyword, existing)

      {:value, key, value_ast} ->
        case Enum.find(options, &(&1.name == to_string(key))) do
          nil -> []
          option -> value_items_for_ast(option.type, value_ast, env)
        end

      :invalid ->
        []
    end
  end

  defp dsl_items(extensions, cursor_path, env) do
    sections = Enum.flat_map(extensions, & &1.sections)
    names = Ast.enclosing_local_call_names(cursor_path)
    call_context = Ast.local_call_at_cursor(cursor_path)
    names = drop_current_partial_call(names, call_context, hint(env))

    current_call_name = if match?({:ok, _, _, _, _}, call_context), do: elem(call_context, 1)

    with {:ok, node} <- Common.find_node(sections, names, current_call_name) do
      {candidates, mode} =
        case call_context do
          {:ok, name, index, argument, arguments} ->
            {dsl_call_candidates(node, name, index, argument, arguments, env),
             completion_mode(node, name)}

          :error ->
            {candidates_for_node(node), :augment}
        end

      completion_items(candidates, env, mode)
    end
  end

  defp completion_items(:error, _env, _mode), do: :error

  defp completion_items({state, candidates, transforms}, env, _mode) do
    {:ok, {state, completion_items(candidates, env), transforms}, state}
  end

  defp completion_items(candidates, env, mode),
    do: {:ok, completion_items(candidates, env), mode}

  defp completion_items(candidates, env) do
    candidates
    |> Enum.filter(fn
      {_candidate, transforms} when is_list(transforms) -> true
      %_{} -> true
      candidate -> matches?(candidate.name, hint(env))
    end)
    |> Enum.map(fn
      {candidate, transforms} when is_list(transforms) -> {candidate, transforms}
      %_{} = candidate -> {candidate, []}
      candidate -> candidate_item(candidate, env)
    end)
    |> Enum.uniq()
  end

  defp completion_mode(%{name: name, arguments: _}, name), do: :override

  defp completion_mode(node, name) do
    if Enum.any?(Map.get(node, :options, []), &(&1.name == name)),
      do: :override,
      else: :augment
  end

  defp drop_current_partial_call(names, {:ok, name, _index, argument, _arguments}, hint)
       when hint != "" do
    if not cursor_in_do_block?(argument) and List.last(names) == name and matches?(name, hint),
      do: Enum.drop(names, -1),
      else: names
  end

  defp drop_current_partial_call(names, _call_context, _hint), do: names

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp dsl_call_candidates(node, name, index, argument_ast, arguments, env) do
    cond do
      node[:name] == name and Map.has_key?(node, :arguments) ->
        case Enum.at(node.arguments, index) do
          nil ->
            trailing_entity_candidates(node, argument_ast, arguments, env)

          argument ->
            values =
              case Enum.find(node.options, &(&1.name == argument.name)) do
                nil -> []
                option -> value_items_for_ast(option.type, argument_ast, env)
              end

            if argument.optional?,
              do:
                merge_value_items([
                  values,
                  trailing_entity_candidates(node, argument_ast, arguments, env)
                ]),
              else: values
        end

      node[:name] == name ->
        candidates_for_node(node)

      option = Enum.find(node.options, &(&1.name == name)) ->
        if index == 0, do: value_items_for_ast(option.type, argument_ast, env), else: []

      hint(env) != "" and matches?(name, hint(env)) ->
        candidates_for_node(node)

      true ->
        :error
    end
  end

  defp trailing_entity_candidates(node, argument_ast, arguments, env) do
    case option_cursor(argument_ast) do
      {:key, existing} ->
        required = for %{name: name, optional?: false} <- node.arguments, do: name

        items =
          node.options
          |> Enum.reject(&(&1.name in required))
          |> option_items(env, :keyword, existing)

        {:override, items, []}

      {:value, key, value_ast} ->
        case Enum.find(node.options, &(&1.name == to_string(key))) do
          nil -> {:override, candidates_for_node(node), []}
          option -> option_value_items(option, node, arguments, value_ast, env)
        end

      _ ->
        {:override, candidates_for_node(node), []}
    end
  end

  defp candidates_for_node(node) do
    Map.get(node, :options, []) ++
      Map.get(node, :entities, []) ++
      Enum.reject(Map.get(node, :sections, []), & &1.top_level?) ++
      Common.top_level_children(node)
  end

  defp candidate_item(%{arguments: _} = entity, _env) do
    snippet = entity.snippet || entity_snippet(entity)

    {%Candidate.Snippet{
       label: entity.name,
       snippet: snippet,
       detail: "DSL Entity",
       documentation: entity.documentation,
       priority: :contextual,
       kind: :function
     }, []}
  end

  defp candidate_item(%{top_level?: _} = section, _env) do
    snippet = section.snippet || "#{section.name} do\n  $0\nend"

    {%Candidate.Snippet{
       label: section.name,
       snippet: snippet,
       detail: "DSL Section",
       documentation: section.documentation,
       priority: :contextual,
       kind: :function
     }, []}
  end

  defp candidate_item(option, env) do
    option_item(option, env, :builder)
  end

  defp entity_snippet(entity) do
    arguments =
      entity.arguments
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {argument, index} -> "${#{index}:#{argument.name}}" end)

    if arguments == "", do: entity.name, else: "#{entity.name} #{arguments}"
  end

  defp option_items(options, env, syntax, existing) do
    options
    |> Enum.reject(&(&1.name in existing))
    |> Enum.filter(&matches?(&1.name, hint(env)))
    |> Enum.map(&option_item(&1, env, syntax))
  end

  defp option_value_items(
         %{name: "constraints", type: fallback},
         node,
         arguments,
         value_ast,
         env
       ) do
    with %{type: %{kind: :spark_type, behaviour: behaviour, aliases: aliases}} <-
           Enum.find(node.options, &(&1.name == "type")),
         index when is_integer(index) <- Enum.find_index(node.arguments, &(&1.name == "type")),
         type_ast when not is_nil(type_ast) <- Enum.at(arguments, index),
         {:ok, module} <- Common.selected_type_module(type_ast, aliases, env),
         {:ok, %{constraints: options}} <-
           Common.fetch(env.project, :behaviour, "#{behaviour}/#{module}") do
      schema_value_items(options, value_ast, env)
    else
      _ -> value_items_for_ast(fallback, value_ast, env)
    end
  end

  defp option_value_items(option, _node, _arguments, value_ast, env),
    do: value_items_for_ast(option.type, value_ast, env)

  defp value_items_for_ast(%{kind: :list, item: item}, value_ast, env) do
    if list_literal?(value_ast) do
      value_items(item, env)
    else
      item
      |> value_items(env)
      |> map_value_items(:wrap_list)
    end
  end

  defp value_items_for_ast(%{kind: :wrap_list, item: item}, value_ast, env),
    do: value_items_for_ast(item, value_ast, env)

  defp value_items_for_ast(%{kind: :or, types: types}, value_ast, env),
    do: types |> Enum.map(&value_items_for_ast(&1, value_ast, env)) |> merge_value_items()

  defp value_items_for_ast(%{kind: :keyword_list, options: options}, value_ast, env),
    do: schema_value_items(options, value_ast, env)

  defp value_items_for_ast(type, _value_ast, env), do: value_items(type, env)

  defp schema_value_items(options, value_ast, env) do
    case schema_items(options, value_ast, env) do
      {_, _, _} = result -> result
      items -> {:override, items, []}
    end
  end

  defp list_literal?(value) when is_list(value), do: true
  defp list_literal?({:__block__, _, [value]}), do: list_literal?(value)
  defp list_literal?(_value), do: false

  defp value_items(%{kind: :choices, values: values}, env) do
    candidates =
      values
      |> Enum.filter(&matches?(&1.label, hint(env)))
      |> Enum.map(fn value ->
        {%Candidate.Snippet{
           label: value.label,
           snippet: value.insert_text,
           detail: "Value",
           priority: :contextual,
           kind: :enum_member
         }, []}
      end)

    {:override, candidates, []}
  end

  defp value_items(%{kind: :boolean}, env) do
    value_items(
      %{
        kind: :choices,
        values: [
          %{label: "true", insert_text: "true"},
          %{label: "false", insert_text: "false"}
        ]
      },
      env
    )
  end

  defp value_items(%{kind: kind} = type, env)
       when kind in [:behaviour, :spark, :spark_behaviour, :spark_function_behaviour] do
    candidates = Enum.map(Values.candidates(env, type), &{&1, []})

    candidates =
      case type do
        %{kind: :spark_function_behaviour, function: %{arity: arity}} ->
          [function_item(arity) | candidates]

        _ ->
          candidates
      end

    {:override, candidates, []}
  end

  defp value_items(%{kind: :function, arity: arity}, _env) do
    {:override, [function_item(arity)], []}
  end

  defp value_items(%{kind: kind, item: item}, env) when kind in [:list, :wrap_list],
    do: value_items(item, env)

  defp value_items(%{kind: :or, types: types}, env),
    do: types |> Enum.map(&value_items(&1, env)) |> merge_value_items()

  defp value_items(_type, _env), do: {:augment, [], []}

  defp map_value_items({state, candidates, transforms}, transform) do
    candidates =
      Enum.map(candidates, fn {candidate, transforms} ->
        {candidate, transforms ++ [transform]}
      end)

    transforms = if state == :augment, do: transforms ++ [transform], else: transforms
    {state, candidates, transforms}
  end

  defp merge_value_items(results) do
    candidates =
      results
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.uniq()

    state = if Enum.all?(results, &(elem(&1, 0) == :override)), do: :override, else: :augment

    transforms =
      Enum.find_value(results, fn
        {:augment, _candidates, transforms} when transforms != [] -> transforms
        _ -> nil
      end) || []

    {state, candidates, transforms}
  end

  defp function_item(arity) do
    {%Candidate.Snippet{
       label: "fn/#{arity || "?"}",
       snippet: function_snippet(arity),
       detail: "Anonymous function",
       priority: :contextual,
       kind: :function
     }, []}
  end

  defp function_snippet(0), do: "fn ->\n  $0\nend"

  defp function_snippet(arity) when is_integer(arity) do
    arguments = Enum.map_join(1..arity, ", ", &"${#{&1}:arg#{&1}}")
    "fn #{arguments} ->\n  $0\nend"
  end

  defp function_snippet(nil), do: "fn ${1:arg} ->\n  $0\nend"

  defp option_item(option, _env, syntax) do
    value = option.snippet || default_snippet(option.type, option.default)
    separator = if syntax == :keyword, do: ": ", else: " "

    {%Candidate.Snippet{
       label: option.name,
       snippet: option.name <> separator <> value,
       detail: "Option",
       documentation: option.documentation,
       priority: :contextual,
       kind: :field
     }, []}
  end

  defp default_snippet(%{kind: :boolean}, default) when default in [true, false],
    do: to_string(not default)

  defp default_snippet(%{kind: :boolean}, _), do: "${1|true,false|}"
  defp default_snippet(%{kind: :string}, _), do: "\"$0\""
  defp default_snippet(%{kind: :atom}, _), do: ":$0"
  defp default_snippet(%{kind: :map}, _), do: "%{${1:key} => ${2:value}}"
  defp default_snippet(%{kind: :keyword_list}, _), do: "[${1:key}: ${2:value}]"
  defp default_snippet(%{kind: :mfa}, _), do: "{${1:Module}, :${2:function}, [${3:args}]}"
  defp default_snippet(%{kind: :function, arity: arity}, _), do: function_snippet(arity)

  defp default_snippet(%{kind: :choices, values: values}, default) do
    default = literal_snippet(default)
    choice = Enum.find(values, &(&1.insert_text != default)) || List.first(values)
    if choice, do: choice.insert_text, else: "$0"
  end

  defp default_snippet(%{kind: kind, item: item}, _) when kind in [:list, :wrap_list] do
    if kind == :list, do: "[#{default_snippet(item, nil)}]", else: default_snippet(item, nil)
  end

  defp default_snippet(_type, _default), do: "$0"

  defp option_cursor({:__cursor__, _, _}), do: {:key, []}
  defp option_cursor({:__block__, _, [value]}), do: option_cursor(value)

  defp option_cursor(options) when is_list(options) do
    without_cursor = Enum.reject(options, &match?({:__cursor__, _, _}, &1))

    if Enum.all?(without_cursor, fn
         {key, _value} -> not is_nil(Common.option_key(key))
         _ -> false
       end) do
      existing =
        without_cursor
        |> Enum.map(fn {key, _value} -> Common.option_key(key) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)

      Enum.find_value(options, {:key, existing}, fn
        {:__cursor__, _, _} ->
          {:key, existing}

        {key, value} ->
          if Ast.contains_cursor?(value), do: {:value, Common.option_key(key), value}

        _ ->
          nil
      end)
    else
      :invalid
    end
  end

  defp option_cursor(_), do: :invalid

  defp cursor_in_do_block?(arguments) when is_list(arguments) do
    Enum.any?(arguments, fn
      {key, value} -> Common.option_key(key) == :do and Ast.contains_cursor?(value)
      _ -> false
    end)
  end

  defp cursor_in_do_block?(_), do: false

  defp literal_snippet(%{atom: atom}) do
    if Regex.match?(~r/^[a-z_][a-zA-Z0-9_@]*[?!]?$/, atom),
      do: ":" <> atom,
      else: ":" <> inspect(atom)
  end

  defp literal_snippet(value) when is_binary(value), do: inspect(value)
  defp literal_snippet(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp literal_snippet(_), do: nil

  defp hint(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {:alias, chars} -> to_string(chars)
      {:alias, _base, chars} -> to_string(chars)
      {:local_or_var, chars} -> to_string(chars)
      {:local_call, chars} -> to_string(chars)
      {:module_attribute, chars} -> to_string(chars)
      {:unquoted_atom, chars} -> to_string(chars)
      _ -> ""
    end
  end

  defp matches?(_name, ""), do: true

  defp matches?(name, hint) do
    name = String.downcase(name)
    hint = String.downcase(hint)

    name =
      if String.starts_with?(name, ":") and not String.starts_with?(hint, ":"),
        do: String.trim_leading(name, ":"),
        else: name

    String.starts_with?(name, hint)
  end
end
