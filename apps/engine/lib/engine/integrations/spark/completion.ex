defmodule Engine.Integrations.Spark.Completion do
  alias Engine.Integrations.Spark.Values
  alias Engine.ManagerApi
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Ast.Analysis.Use
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  def complete(%Env{} = env) do
    if Env.in_context?(env, :comment) or Env.in_context?(env, :string) do
      :ignore
    else
      cursor_path = Ast.cursor_path(env.analysis, env.position)

      case use_context(cursor_path, env) do
        {:ok, module, argument} ->
          case fetch(env.project, :dsl, module) do
            {:ok, dsl} -> completion_result(schema_items(dsl.options, argument, env), :override)
            :error -> :ignore
          end

        :error ->
          with {:ok, module, name, arity, argument_index, argument} <-
                 function_context(cursor_path, env),
               key = "#{Forge.Formats.mfa(module, name, arity)}/#{argument_index}",
               {:ok, options} <- fetch(env.project, :function, key) do
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
      case dsl_context(project, env) do
        {:ok, dsl, use} ->
          extensions = active_extensions(fetch_extensions(project), dsl, use, env)

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
      Enum.any?(cursor_path, fn
        {{:., _, _}, _, arguments} when is_list(arguments) -> true
        _ -> false
      end)
  end

  defp use_context(cursor_path, env) do
    Enum.find_value(cursor_path, :error, fn
      {:use, _, [module_ast | arguments]} ->
        with {:ok, module} <- expand_module(module_ast, env) do
          {:ok, module, List.last(arguments)}
        end

      _ ->
        nil
    end)
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

  defp dsl_context(project, %Env{} = env) do
    env.analysis
    |> Analysis.scopes_at(env.position)
    |> List.first()
    |> case do
      %Scope{} = scope ->
        scope.uses
        |> Enum.filter(&before_cursor?(&1, env))
        |> Enum.find_value(:error, fn %Use{} = use ->
          dsl_for_use(project, use, env)
        end)

      _ ->
        :error
    end
  end

  defp dsl_for_use(project, %Use{} = use, %Env{} = env) do
    env = %Env{env | position: use.range.start}

    case expand_segments(use.module, env) do
      {:ok, module} ->
        case fetch(project, :dsl, module) do
          {:ok, dsl} -> {:ok, dsl, use}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp before_cursor?(%Use{range: range}, %Env{} = env) do
    range.end.line < env.position.line or
      (range.end.line == env.position.line and range.end.character <= env.position.character)
  end

  defp active_extensions(extensions, dsl, %Use{} = use, env) do
    configured = configured_extensions(use, dsl, env)

    defaults =
      Enum.reduce(dsl.single_extension_kinds, dsl.default_extensions, fn kind, defaults ->
        if Map.get(configured, kind, []) == [] do
          defaults
        else
          defaults -- Map.get(dsl.default_extension_kinds, kind, [])
        end
      end)

    (defaults ++ Enum.flat_map(configured, fn {_kind, extensions} -> extensions end))
    |> Enum.uniq()
    |> expand_extensions(extensions, %{})
    |> apply_patches()
  end

  defp configured_extensions(%Use{opts: opts} = use, dsl, %Env{} = env) do
    env = %Env{env | position: use.range.start}
    extension_keys = ["extensions" | dsl.extension_kinds]

    Enum.reduce(List.flatten(opts), %{}, fn
      {key_ast, value}, acc ->
        case option_key(key_ast) do
          key when is_atom(key) and not is_nil(key) ->
            key = to_string(key)

            if key in extension_keys do
              extensions = modules_from_ast(value, env)
              Map.update(acc, key, extensions, &(&1 ++ extensions))
            else
              acc
            end

          nil ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp option_key(key) when is_atom(key), do: key
  defp option_key({:__block__, _, [key]}) when is_atom(key), do: key
  defp option_key(_), do: nil

  defp expand_extensions([], _extensions, _seen), do: []

  defp expand_extensions([module | rest], extensions, seen) do
    if Map.has_key?(seen, module) do
      expand_extensions(rest, extensions, seen)
    else
      seen = Map.put(seen, module, true)

      case Map.fetch(extensions, module) do
        {:ok, extension} ->
          [extension | expand_extensions(extension.added_extensions ++ rest, extensions, seen)]

        :error ->
          expand_extensions(rest, extensions, seen)
      end
    end
  end

  defp apply_patches(extensions) do
    patches = Enum.flat_map(extensions, & &1.patches)

    Enum.map(extensions, fn extension ->
      %{extension | sections: patch_sections(extension.sections, patches, [])}
    end)
  end

  defp patch_sections(sections, patches, path) do
    Enum.map(sections, fn section ->
      section_path = path ++ [section.name]

      patched_entities =
        for %{section_path: ^section_path, entity: entity} <- patches, do: entity

      %{
        section
        | entities: section.entities ++ patched_entities,
          sections: patch_sections(section.sections, patches, section_path)
      }
    end)
  end

  defp dsl_items(extensions, cursor_path, env) do
    sections = Enum.flat_map(extensions, & &1.sections)
    names = enclosing_call_names(cursor_path)
    call_context = local_call_context(cursor_path)
    names = drop_current_partial_call(names, call_context, hint(env))

    current_call_name = if match?({:ok, _, _, _, _}, call_context), do: elem(call_context, 1)

    with {:ok, node} <- find_node(sections, names, current_call_name) do
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

  defp enclosing_call_names(cursor_path) do
    cursor_path
    |> Enum.flat_map(fn
      {name, _, args}
      when is_atom(name) and is_list(args) and
             name not in [:__cursor__, :__block__, :defmodule, :use] ->
        [to_string(name)]

      _ ->
        []
    end)
    |> Enum.reverse()
  end

  defp find_node(sections, names, current_call_name) do
    root = %{options: [], entities: [], sections: sections}
    last_name = List.last(names)

    Enum.reduce_while(names, {:ok, root}, fn name, {:ok, node} ->
      case child(node, name) do
        nil when name == last_name and name == current_call_name -> {:halt, {:ok, node}}
        nil -> {:halt, :error}
        child -> {:cont, {:ok, child}}
      end
    end)
  end

  defp child(node, name) do
    Enum.find(Map.get(node, :sections, []), &(&1.name == name)) ||
      Enum.find(Map.get(node, :entities, []), &(&1.name == name)) ||
      Enum.find(top_level_children(node), &(&1.name == name))
  end

  defp candidates_for_node(node) do
    Map.get(node, :options, []) ++
      Map.get(node, :entities, []) ++
      Enum.reject(Map.get(node, :sections, []), & &1.top_level?) ++ top_level_children(node)
  end

  defp top_level_children(node) do
    node
    |> Map.get(:sections, [])
    |> Enum.filter(& &1.top_level?)
    |> Enum.flat_map(fn section -> section.options ++ section.entities ++ section.sections end)
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
         {:ok, module} <- selected_type_module(type_ast, aliases, env),
         {:ok, %{constraints: options}} <-
           fetch(env.project, :behaviour, "#{behaviour}/#{module}") do
      schema_value_items(options, value_ast, env)
    else
      _ -> value_items_for_ast(fallback, value_ast, env)
    end
  end

  defp option_value_items(option, _node, _arguments, value_ast, env),
    do: value_items_for_ast(option.type, value_ast, env)

  defp selected_type_module({:__block__, _, [value]}, aliases, env),
    do: selected_type_module(value, aliases, env)

  defp selected_type_module(value, aliases, _env) when is_atom(value),
    do: Map.fetch(aliases, to_string(value))

  defp selected_type_module(value, _aliases, env) do
    with {:ok, module} <- expand_module(value, env), do: {:ok, module_name(module)}
  end

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

  defp local_call_context(cursor_path) do
    Enum.find_value(cursor_path, :error, fn
      {name, _, arguments}
      when is_atom(name) and is_list(arguments) and
             name not in [:__cursor__, :__block__, :defmodule, :use, :|>] ->
        case cursor_argument(arguments) do
          {:ok, index, argument} -> {:ok, to_string(name), index, argument, arguments}
          :error -> nil
        end

      _ ->
        nil
    end)
  end

  defp function_context(cursor_path, env) do
    Enum.find_value(cursor_path, fn
      {:|>, _, [_left, call]} ->
        remote_function_context(call, env, 1)

      _ ->
        nil
    end) || Enum.find_value(cursor_path, :error, &remote_function_context(&1, env, 0))
  end

  defp remote_function_context({{:., _, [module_ast, name]}, _, arguments}, env, offset)
       when is_atom(name) and is_list(arguments) do
    with {:ok, module} <- expand_module(module_ast, env),
         {:ok, index, argument} <- cursor_argument(arguments) do
      {:ok, module, name, length(arguments) + offset, index + offset, argument}
    else
      _ -> nil
    end
  end

  defp remote_function_context(_ast, _env, _offset), do: nil

  defp cursor_argument(arguments) do
    arguments
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {argument, index} ->
      if contains_cursor?(argument), do: {:ok, index, argument}
    end)
  end

  defp option_cursor({:__cursor__, _, _}), do: {:key, []}
  defp option_cursor({:__block__, _, [value]}), do: option_cursor(value)

  defp option_cursor(options) when is_list(options) do
    without_cursor = Enum.reject(options, &match?({:__cursor__, _, _}, &1))

    if Enum.all?(without_cursor, fn
         {key, _value} -> not is_nil(option_key(key))
         _ -> false
       end) do
      existing =
        without_cursor
        |> Enum.map(fn {key, _value} -> option_key(key) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)

      Enum.find_value(options, {:key, existing}, fn
        {:__cursor__, _, _} -> {:key, existing}
        {key, value} -> if contains_cursor?(value), do: {:value, option_key(key), value}
        _ -> nil
      end)
    else
      :invalid
    end
  end

  defp option_cursor(_), do: :invalid

  defp contains_cursor?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:__cursor__, _, _} = node, _ -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp cursor_in_do_block?(arguments) when is_list(arguments) do
    Enum.any?(arguments, fn
      {key, value} -> option_key(key) == :do and contains_cursor?(value)
      _ -> false
    end)
  end

  defp cursor_in_do_block?(_), do: false

  defp modules_from_ast(list, env) when is_list(list),
    do: Enum.flat_map(list, &modules_from_ast(&1, env))

  defp modules_from_ast({:__block__, _, [value]}, env), do: modules_from_ast(value, env)

  defp modules_from_ast(ast, env) do
    case expand_module(ast, env) do
      {:ok, module} -> [module_name(module)]
      :error -> []
    end
  end

  defp expand_module({:__aliases__, _, segments}, env), do: expand_segments(segments, env)
  defp expand_module({:__block__, _, [value]}, env), do: expand_module(value, env)
  defp expand_module({:__MODULE__, _, _}, env), do: expand_segments([:__MODULE__], env)
  defp expand_module(module, _env) when is_atom(module), do: {:ok, Atom.to_string(module)}
  defp expand_module(_, _env), do: :error

  defp expand_segments(segments, %Env{} = env) do
    case Analysis.scopes_at(env.analysis, env.position) do
      [%Scope{} = scope | _] ->
        aliases = Scope.alias_map(scope, env.position)

        case segments do
          [:__MODULE__ | suffix] ->
            resolve_alias(aliases, :__MODULE__, suffix)

          [prefix | suffix] ->
            if Map.has_key?(aliases, [prefix]),
              do: resolve_alias(aliases, prefix, suffix),
              else: {:ok, Module.concat(segments)}
        end

      _ ->
        {:ok, Module.concat(segments)}
    end
  rescue
    _ in ArgumentError -> :error
  end

  defp resolve_alias(aliases, prefix, suffix) do
    case Map.get(aliases, [prefix]) do
      %Alias{} = alias -> {:ok, Module.concat([Alias.to_module(alias) | suffix])}
      _ -> :error
    end
  end

  defp literal_snippet(%{atom: atom}) do
    if Regex.match?(~r/^[a-z_][a-zA-Z0-9_@]*[?!]?$/, atom),
      do: ":" <> atom,
      else: ":" <> inspect(atom)
  end

  defp literal_snippet(value) when is_binary(value), do: inspect(value)
  defp literal_snippet(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp literal_snippet(_), do: nil

  defp fetch(project, kind, module) do
    subject = Entry.integration_subject("spark", kind, module)

    case ManagerApi.search_store_exact(project, subject,
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, [%Entry{metadata: %{payload: payload}} | _]} -> {:ok, payload}
      _ -> :error
    end
  end

  defp fetch_extensions(project) do
    case ManagerApi.search_store_prefix(
           project,
           Entry.integration_subject_prefix("spark", :extension),
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, entries} ->
        Map.new(entries, fn %Entry{metadata: %{owner_module: module, payload: payload}} ->
          {module, payload}
        end)

      _ ->
        %{}
    end
  end

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

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(module) when is_binary(module), do: module
end
