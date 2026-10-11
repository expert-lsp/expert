defmodule ExpertPhoenix do
  @moduledoc "Provides code intelligence for Phoenix routes."

  Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
    accumulate: true,
    persist: true
  )

  @elixir_semantic_metadata {:elixir_semantic_metadata_v1, ExpertPhoenix.Metadata.document()}

  @route_arguments (for %{mfa: mfa, argument: index, scope: scope} <-
                          ExpertPhoenix.Metadata.document().contexts,
                        scope in [:controllers, :plugs, :live_views, :actions],
                        reduce: %{} do
                      routes ->
                        key = if scope == :actions, do: :action, else: :module

                        Map.update(routes, mfa, %{key => index}, &Map.put(&1, key, index))
                    end)

  def complete(%{semantic: %{scope: scope}} = request) do
    case scope do
      :controllers -> module_items(request, &controller?/1, "Phoenix controller")
      :plugs -> module_items(request, &plug?/1, "Plug")
      :live_views -> module_items(request, &live_view?/1, "Phoenix LiveView")
      :actions -> action_items(request)
    end
  end

  def resolve(%{semantic: %{scope: :actions}, identifier: identifier} = request)
      when is_binary(identifier) do
    with {:ok, controller} <- route_controller(request),
         true <- controller?(controller),
         action when action != nil <- existing_atom(identifier),
         true <- function_exported?(controller, action, 2) do
      %{entity: %{kind: :function, module: controller, name: action, arity: 2}}
    else
      _ -> nil
    end
  end

  def resolve(%{identifier: identifier} = request) when is_binary(identifier) do
    {segments, range} = alias_at_cursor(request)
    module = scoped_module(scope_alias(request), request.aliases, segments)

    if module != nil and Code.ensure_loaded?(module),
      do: %{entity: %{kind: :module, module: module}, range: range}
  end

  def resolve(_request), do: nil

  def references(%{entity: entity, files: files}) do
    for %{path: path, calls: calls} <- files,
        {:ok, source} <- [File.read(path)],
        {:ok, ast} <- [parse(source, path)],
        targets = Map.new(calls, &{{&1.position.line, &1.position.character}, &1.target}),
        range <- route_references(ast, targets, entity),
        do: %{path: path, range: range}
  end

  defp parse(source, path) do
    Code.string_to_quoted(source,
      file: path,
      columns: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}}
    )
  end

  defp route_references(ast, targets, entity) do
    ast
    |> walk(%{scope: nil, aliases: %{}, targets: targets}, entity, [])
    |> Enum.reverse()
  end

  defp walk({:__block__, _meta, expressions}, state, entity, acc) when is_list(expressions) do
    {acc, _state} =
      Enum.reduce(expressions, {acc, state}, fn
        {:alias, _meta, arguments}, {acc, state} when is_list(arguments) ->
          {acc, %{state | aliases: put_alias(state.aliases, arguments)}}

        expression, {acc, state} ->
          {walk(expression, state, entity, acc), state}
      end)

    acc
  end

  defp walk({:scope, _meta, arguments}, state, entity, acc) when is_list(arguments) do
    scope = nest_scope(state.scope, arguments, state.aliases)
    walk(arguments, %{state | scope: scope}, entity, acc)
  end

  defp walk({_call, meta, arguments} = node, state, entity, acc) when is_list(arguments) do
    acc =
      case Map.fetch(state.targets, {meta[:line], meta[:column]}) do
        {:ok, target} -> Enum.reverse(route_ranges(node, target, state, entity), acc)
        :error -> acc
      end

    walk(arguments, state, entity, acc)
  end

  defp walk({left, right}, state, entity, acc),
    do: walk(right, state, entity, walk(left, state, entity, acc))

  defp walk(list, state, entity, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, state, entity, &2))

  defp walk(_node, _state, _entity, acc), do: acc

  defp route_ranges({_route, _meta, arguments}, target, state, entity) do
    with {:__aliases__, meta, _segments} = node <- route_argument(arguments, target, :module),
         {:ok, segments} <- segments(node) do
      module = scoped_module(state.scope, state.aliases, segments)
      action = route_argument(arguments, target, :action)
      alias_range(entity, module, meta, segments) ++ action_range(entity, module, action)
    else
      _ -> []
    end
  end

  defp route_argument(arguments, target, key) do
    case @route_arguments do
      %{^target => %{^key => index}} -> Enum.at(arguments, index)
      %{} -> nil
    end
  end

  defp alias_range(%{kind: :module, module: module}, module, meta, segments),
    do: [range(meta, segments |> Enum.map_join(".", &Atom.to_string/1) |> columns())]

  defp alias_range(_entity, _module, _meta, _segments), do: []

  defp action_range(
         %{kind: :function, module: module, name: action, arity: 2},
         module,
         {:__block__, meta, [action]}
       ),
       do: [range(meta, columns(inspect(action)))]

  defp action_range(_entity, _module, _argument), do: []

  defp range(meta, length) do
    line = meta[:line]
    column = meta[:column]
    %{start: %{line: line, character: column}, end: %{line: line, character: column + length}}
  end

  defp put_alias(aliases, [{:__aliases__, _meta, _segments} = node | options]) do
    case segments(node) do
      {:ok, segments} ->
        as =
          with [keywords] <- options,
               keywords when is_list(keywords) <- literal(keywords),
               {:__aliases__, _, [as]} <- option(keywords, :as) do
            as
          else
            _ -> List.last(segments)
          end

        Map.put(aliases, [as], expand(aliases, segments))

      :error ->
        aliases
    end
  end

  defp put_alias(aliases, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]) do
    for {:__aliases__, _meta, segments} <- children, reduce: aliases do
      aliases -> Map.put(aliases, [List.last(segments)], expand(aliases, base ++ segments))
    end
  end

  defp put_alias(aliases, _arguments), do: aliases

  defp module_items(request, select?, detail) do
    scope = scope_alias(request)
    prefix = if scope, do: scope <> ".", else: ""
    namespace = if scope, do: nil, else: namespace(request)
    typed = typed_alias(request)

    if prefix == "" and typed == "" do
      []
    else
      for {app, _description, _version} <- Application.loaded_applications(),
          module <- Application.spec(app, :modules) || [],
          "Elixir." <> name <- [Atom.to_string(module)],
          String.starts_with?(name, prefix),
          relative = String.replace_prefix(name, prefix, ""),
          relative != "" and matches?(relative, typed, namespace),
          select?.(module) do
        %{
          label: relative,
          kind: :class,
          detail: "#{detail} #{name}",
          range: typed_range(request, typed)
        }
      end
      |> Enum.sort_by(& &1.label)
    end
  end

  defp matches?(name, typed, namespace) do
    cond do
      String.contains?(typed, ".") ->
        String.starts_with?(name, typed)

      namespace == nil ->
        Enum.any?([name | String.split(name, ".")], &String.starts_with?(&1, typed))

      true ->
        case String.split(name, ".") do
          [^namespace | segments] -> Enum.any?(segments, &String.starts_with?(&1, typed))
          _segments -> false
        end
    end
  end

  defp namespace(%{module: module}) when is_binary(module),
    do: module |> String.split(".") |> hd()

  defp namespace(_request), do: ""

  defp action_items(request) do
    with {:ok, controller} <- route_controller(request),
         true <- controller?(controller) do
      hint = request.hint
      typed = if String.ends_with?(line_prefix(request), ":" <> hint), do: ":" <> hint, else: hint

      for {name, 2} <- controller.__info__(:functions),
          name not in [:action, :call],
          String.starts_with?(Atom.to_string(name), hint) do
        %{
          label: inspect(name),
          kind: :function,
          detail: "Phoenix action",
          range: typed_range(request, typed)
        }
      end
    else
      _ -> []
    end
  end

  defp alias_at_cursor(%{identifier: identifier, range: %{start: start}, position: position}) do
    {before, rest} = split_at(identifier, position.character - start.character)
    [tail | _rest] = String.split(rest, ".", parts: 2)
    text = before <> tail
    range = %{start: start, end: %{start | character: start.character + columns(text)}}
    {String.split(text, "."), range}
  end

  defp typed_alias(request) do
    case Code.Fragment.cursor_context(line_prefix(request)) do
      {:alias, chars} -> to_string(chars)
      {:dot, {:alias, base}, chars} -> "#{base}.#{chars}"
      _context -> ""
    end
  end

  defp route_controller(%{call: %{args: args, target: target}} = request) do
    with {:ok, segments} <- segments(route_argument(args, target, :module)),
         do: {:ok, scoped_module(scope_alias(request), request.aliases, segments)}
  end

  defp typed_range(%{position: %{line: line, character: character}}, typed) do
    %{
      start: %{line: line, character: character - columns(typed)},
      end: %{line: line, character: character}
    }
  end

  defp line_prefix(%{source: source, position: %{line: line, character: character}}) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> String.to_charlist()
    |> Enum.take(character - 1)
    |> List.to_string()
  end

  defp scope_alias(%{ancestors: ancestors, aliases: aliases}) do
    for {:scope, _, arguments} <- Enum.reverse(ancestors), reduce: nil do
      scope -> nest_scope(scope, arguments, aliases)
    end
  end

  defp nest_scope(scope, arguments, aliases) do
    case scope_option(arguments) do
      false ->
        nil

      nil ->
        scope

      alias ->
        case segments(alias) do
          {:ok, nested} -> scoped_name(scope, aliases, nested)
          :error -> scope
        end
    end
  end

  defp scope_option(arguments) do
    case Enum.map(Enum.take(arguments, 2), &literal/1) do
      [options | _rest] when is_list(options) -> option(options, :alias)
      [_path, {:__aliases__, _, _} = alias] -> alias
      [_path, options] when is_list(options) -> option(options, :alias)
      _arguments -> nil
    end
  end

  defp option(options, key) do
    case for({name, value} <- options, literal(name) == key, do: literal(value)) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp scoped_module(scope, aliases, segments),
    do: scope |> scoped_name(aliases, segments) |> existing_module()

  defp scoped_name(nil, aliases, segments), do: expand(aliases, segments)
  defp scoped_name(scope, _aliases, segments), do: module_name([scope | segments])

  defp expand(aliases, [first | rest]) do
    first = to_string(first)

    aliased =
      Enum.find_value(aliases, fn
        {[segment], module} -> if Atom.to_string(segment) == first, do: module
        _alias -> nil
      end)

    module_name([aliased || first | rest])
  end

  defp existing_module(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end

  defp module_name(parts) do
    parts
    |> Enum.flat_map(fn
      module when is_atom(module) -> module_parts(module)
      name when is_binary(name) -> String.split(name, ".", trim: true)
    end)
    |> Enum.join(".")
  end

  defp module_parts(module) do
    case Atom.to_string(module) do
      "Elixir." <> _name -> Module.split(module)
      segment -> [segment]
    end
  end

  defp segments({:__aliases__, _meta, segments}) do
    if Enum.all?(segments, &is_atom/1), do: {:ok, segments}, else: :error
  end

  defp segments(_node), do: :error

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp columns(text), do: text |> String.to_charlist() |> length()

  defp split_at(text, count) do
    {before, rest} = text |> String.to_charlist() |> Enum.split(count)
    {List.to_string(before), List.to_string(rest)}
  end

  defp controller?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :action, 2) and
      function_exported?(module, :call, 2)
  end

  defp plug?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
      function_exported?(module, :call, 2)
  end

  defp live_view?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__live__, 0)

  defp literal({:__block__, _meta, [value]}) when is_atom(value) or is_list(value), do: value
  defp literal(value), do: value
end
