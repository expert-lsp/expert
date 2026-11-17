defmodule ExpertEcto do
  @moduledoc "Provides Ecto code intelligence through semantic metadata."

  Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
    accumulate: true,
    persist: true
  )

  @elixir_semantic_metadata {:elixir_semantic_metadata_v1, ExpertEcto.Metadata.document()}

  @joins ExpertEcto.Metadata.joins()

  @type_callbacks [
    [type: 0, cast: 1, dump: 1, load: 1],
    [type: 1, cast: 2, dump: 3, load: 3]
  ]

  def complete(%{semantic: %{scope: scope}} = request) do
    case scope do
      :expressions -> expression_items(request)
      :query_sources -> source_items(request)
      :field_types -> type_items(request)
      :schemas -> module_items(request, &schema?/1, :struct)
    end
  end

  def resolve(%{identifier: identifier, call: %{ast: call}} = request)
      when is_binary(identifier) do
    parents = [request.module | enclosing_embeds(request)]
    module = existing_module(parents ++ [identifier])

    if inline_embed?(request.source, call) and module != nil and Code.ensure_loaded?(module),
      do: %{entity: %{kind: :module, module: module}}
  end

  def resolve(_request), do: nil

  defp inline_embed?(source, {embed, meta, _arguments}) do
    location = {meta[:line], meta[:column]}

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.any?(fn
          {^embed, call_meta, arguments} ->
            {call_meta[:line], call_meta[:column]} == location and do_block?(arguments)

          _node ->
            false
        end)

      {:error, _error} ->
        false
    end
  end

  defp enclosing_embeds(%{ancestors: ancestors}) do
    for {embed, _, arguments} when embed in [:embeds_one, :embeds_many] <-
          Enum.reverse(ancestors),
        [_name, {:__aliases__, _, segments} | _rest] = arguments <- [unwrap_literals(arguments)],
        do_block?(arguments),
        segment <- segments,
        do: segment
  end

  defp do_block?(arguments) do
    case List.last(arguments) do
      [_ | _] = options -> Keyword.keyword?(options) and Keyword.has_key?(options, :do)
      _argument -> false
    end
  end

  defp expression_items(request) do
    bindings = bindings(request)

    case Code.Fragment.cursor_context(line_prefix(request)) do
      {:dot, {:var, binding}, hint} ->
        for field <- bindings |> binding_schema(to_string(binding)) |> schema_fields(),
            name = Atom.to_string(field),
            String.starts_with?(name, to_string(hint)),
            do: %{label: name, insert_text: name, kind: :field}

      {:dot, _base, _hint} ->
        []

      _context ->
        for {binding, _schema} <- bindings,
            name = Atom.to_string(binding),
            String.starts_with?(name, request.hint),
            do: %{label: name, insert_text: name, kind: :variable}
    end
  end

  defp source_items(request) do
    case Enum.find_value(request.ancestors, &assoc_binding/1) do
      nil ->
        module_items(request, &schema?/1, :struct)

      binding ->
        schema = request |> bindings() |> binding_schema(binding)

        for association <- schema_associations(schema),
            name = Atom.to_string(association),
            String.starts_with?(name, request.hint),
            do: %{label: inspect(association), insert_text: inspect(association), kind: :field}
    end
  end

  defp assoc_binding({:assoc, _, [{binding, _, context}, {:__cursor__, _, _}]})
       when is_atom(binding) and is_atom(context),
       do: Atom.to_string(binding)

  defp assoc_binding(_ancestor), do: nil

  defp type_items(request) do
    prefix = line_prefix(request)
    [typed] = Regex.run(~r/\{?:?\w*$/, prefix)
    %{line: line, character: character} = request.position

    range = %{
      start: %{line: line, character: character - columns(typed)},
      end: %{line: line, character: character}
    }

    composites =
      for {name, detail} <- [array: "list", map: "map"],
          String.starts_with?(Atom.to_string(name), request.hint) do
        %{
          label: "{:#{name}, inner_type}",
          filter_text: typed,
          snippet: "{:#{name}, ${1:inner_type}}",
          detail: detail,
          kind: :type_parameter,
          range: range
        }
      end

    composites ++ module_items(request, &custom_type?/1, :type_parameter)
  end

  defp module_items(%{hint: ""}, _select?, _kind), do: []

  defp module_items(%{hint: hint} = request, select?, kind) do
    namespace = request.module && request.module |> String.split(".") |> hd()

    for {app, _description, _version} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        "Elixir." <> alias <- [Atom.to_string(module)],
        matches?(alias, hint, namespace),
        select?.(module) do
      %{label: alias, insert_text: alias, kind: kind}
    end
  end

  defp matches?(alias, hint, namespace) do
    if String.contains?(hint, ".") do
      String.starts_with?(alias, hint)
    else
      case String.split(alias, ".") do
        [^namespace | segments] -> Enum.any?(segments, &String.starts_with?(&1, hint))
        _segments -> false
      end
    end
  end

  defp bindings(%{call: %{args: args}, aliases: aliases}) do
    case unwrap_literals(args) do
      [{:in, _, [{binding, _, context}, source]} | options]
      when is_atom(binding) and is_atom(context) ->
        for {join, {:in, _, [{binding, _, context}, source]}} <- List.flatten(options),
            join in @joins and is_atom(binding) and is_atom(context),
            reduce: [{binding, source_schema(source, aliases, [])}] do
          bindings -> [{binding, source_schema(source, aliases, bindings)} | bindings]
        end
        |> Enum.reverse()

      _args ->
        []
    end
  end

  defp binding_schema(bindings, name) do
    Enum.find_value(bindings, fn {binding, schema} ->
      if Atom.to_string(binding) == name, do: schema
    end)
  end

  defp source_schema({:__aliases__, _, [first | rest]}, aliases, _bindings) do
    case aliases do
      %{[^first] => module} -> existing_module([module | rest])
      %{} -> existing_module([first | rest])
    end
  end

  defp source_schema({:assoc, _, [{parent, _, context}, association]}, _aliases, bindings)
       when is_atom(parent) and is_atom(context) and is_atom(association) do
    schema = binding_schema(bindings, Atom.to_string(parent))

    with true <- schema?(schema),
         %{related: related} when is_atom(related) <-
           schema.__schema__(:association, association) do
      related
    else
      _ -> nil
    end
  end

  defp source_schema(_source, _aliases, _bindings), do: nil

  defp schema_fields(schema), do: if(schema?(schema), do: schema.__schema__(:fields), else: [])

  defp schema_associations(schema),
    do: if(schema?(schema), do: schema.__schema__(:associations), else: [])

  defp schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)

  defp custom_type?(module) do
    Code.ensure_loaded?(module) and
      Enum.any?(@type_callbacks, fn callbacks ->
        Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
      end)
  end

  defp existing_module(parts) do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))) do
      name =
        parts
        |> Enum.flat_map(fn
          module when is_atom(module) -> module_parts(module)
          name when is_binary(name) -> String.split(name, ".", trim: true)
        end)
        |> Enum.join(".")

      String.to_existing_atom("Elixir." <> name)
    end
  rescue
    ArgumentError -> nil
  end

  defp module_parts(module) do
    case Atom.to_string(module) do
      "Elixir." <> _name -> Module.split(module)
      segment -> [segment]
    end
  end

  defp unwrap_literals(ast) do
    Macro.prewalk(ast, fn
      {:__block__, _meta, [literal]} when is_atom(literal) or is_list(literal) -> literal
      node -> node
    end)
  end

  defp line_prefix(%{source: source, position: %{line: line, character: character}}) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> String.to_charlist()
    |> Enum.take(character - 1)
    |> List.to_string()
  end

  defp columns(text), do: text |> String.to_charlist() |> length()
end
