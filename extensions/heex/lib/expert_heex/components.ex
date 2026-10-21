defmodule ExpertHEEx.Components do
  @moduledoc false

  # Elixir imports these modules by default. A module can narrow that with
  # `import Kernel, except: [...]`, and the imports of the request already
  # reflect it. Their remaining arity-1 functions, such as `hd/1`, are not
  # components.
  @default_imports [Kernel, Kernel.SpecialForms]

  def local(request) do
    request |> local_functions() |> function_items()
  end

  def remote(request, alias) do
    module = expand_alias(request, alias)
    function_items(for name <- public_functions(module), do: {module, name})
  end

  def attributes(request, tag, present) do
    request |> component(tag) |> Map.get(:attrs, []) |> attribute_items(present)
  end

  def slots(request, tag) do
    for slot <- request |> component(tag) |> Map.get(:slots, []),
        slot.name != :inner_block do
      name = Atom.to_string(slot.name)

      %{label: name, kind: :property, insert_text: name, detail: "slot" <> required(slot)}
      |> put_documentation(slot.doc)
    end
  end

  def slot_attributes(request, tag, slot, present) do
    case request |> component(tag) |> find(:slots, slot) do
      nil -> []
      slot -> attribute_items(slot.attrs, present)
    end
  end

  def describe(request, {:component, tag}) do
    with {:ok, module, function, declaration} <- declaration(request, tag) do
      docs = function_docs(module)[function] || declarations(declaration)
      join(["`#{inspect(module)}.#{function}/1`", docs])
    else
      _ -> nil
    end
  end

  def describe(request, reference) do
    request
    |> component(component_tag(reference))
    |> declared(reference)
    |> describe_declared(reference)
  end

  def locate(request, {:component, tag}) do
    with {:ok, module, function, declaration} <- declaration(request, tag) do
      location(module, declaration[:line] || doc_line(module, function))
    else
      _ -> []
    end
  end

  def locate(request, reference) do
    with {:ok, module, _function, declaration} <- declaration(request, component_tag(reference)),
         %{line: line} <- declared(declaration, reference) do
      location(module, line)
    else
      _ -> []
    end
  end

  defp declared(declaration, {:slot, _component, ":" <> slot}),
    do: find(declaration, :slots, slot)

  defp declared(declaration, {:attribute, _tag, attribute}),
    do: find(declaration, :attrs, attribute)

  defp declared(declaration, {:slot_attribute, _component, ":" <> slot, attribute}),
    do: declaration |> find(:slots, slot) |> find(:attrs, attribute)

  defp component_tag({:slot, component, _slot}), do: component
  defp component_tag({:attribute, tag, _attribute}), do: tag
  defp component_tag({:slot_attribute, component, _slot, _attribute}), do: component

  defp location(_module, nil), do: []

  defp location(module, line) do
    case module.module_info(:compile)[:source] do
      source when is_list(source) ->
        point = %{line: line, character: 1}
        [%{path: List.to_string(source), range: %{start: point, end: point}}]

      _source ->
        []
    end
  end

  defp find(%{} = declaration, key, name),
    do: Enum.find(Map.get(declaration, key, []), &(Atom.to_string(&1.name) == name))

  defp find(nil, _key, _name), do: nil

  defp describe_declared(nil, _reference), do: nil

  defp describe_declared(slot, {:slot, _component, _slot}),
    do: join(["`:#{slot.name}` slot" <> required(slot), slot.doc, declarations(slot)])

  defp describe_declared(attr, _reference),
    do: join(["`#{attr.name}` `#{inspect(attr.type)}`" <> required(attr), attr.doc])

  defp declarations(declaration) do
    attributes =
      for attr <- Map.get(declaration, :attrs, []), attr.type != :global do
        "* `#{attr.name}` `#{inspect(attr.type)}`" <> required(attr) <> doc_suffix(attr)
      end

    slots =
      for slot <- Map.get(declaration, :slots, []) do
        "* `#{slot.name}`" <> required(slot) <> doc_suffix(slot)
      end

    join([
      if(attributes != [], do: Enum.join(["**Attributes**", "" | attributes], "\n")),
      if(slots != [], do: Enum.join(["**Slots**", "" | slots], "\n"))
    ])
  end

  defp required(declaration), do: if(declaration.required, do: " (required)", else: "")

  defp doc_suffix(%{doc: doc}) when is_binary(doc), do: " - " <> doc
  defp doc_suffix(_declaration), do: ""

  defp join(parts) do
    case Enum.reject(parts, &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp declaration(request, tag) do
    with {:ok, module, function} <- resolve(request, tag),
         do: {:ok, module, function, module |> components() |> Map.get(function, %{})}
  end

  defp component(request, tag) do
    case declaration(request, tag) do
      {:ok, _module, _function, declaration} -> declaration
      :error -> %{}
    end
  end

  defp attribute_items(attrs, present) do
    for attr <- Enum.sort_by(attrs, &(not &1.required)),
        attr.type != :global,
        Atom.to_string(attr.name) not in present,
        do: attribute_item(attr)
  end

  def assigns(request) do
    with module when not is_nil(module) <- current_module(request),
         {:ok, name} <- enclosing_function(request.ancestors),
         %{attrs: attrs, slots: slots} <- components(module)[name] do
      Enum.map(attrs, &assign_item(&1, "attr")) ++ Enum.map(slots, &assign_item(&1, "slot"))
    else
      _ -> []
    end
  end

  defp local_functions(request) do
    current =
      case current_module(request) do
        nil -> []
        module -> for name <- functions(module, :all), do: {module, name}
      end

    imported =
      for {module, name, 1} <- request.imports,
          module not in @default_imports,
          do: {module, name}

    Enum.uniq(current ++ imported)
  end

  defp public_functions(module), do: functions(module, :public)

  defp functions(module, visibility) do
    if Code.ensure_loaded?(module) do
      functions =
        case visibility do
          :all -> module.module_info(:functions)
          :public -> module.module_info(:exports)
        end

      for {name, 1} <- functions, user_defined?(name), do: name
    else
      []
    end
  end

  defp user_defined?(name) do
    name = Atom.to_string(name)

    not (String.starts_with?(name, ["__", "-", "MACRO-"]) or String.contains?(name, " ") or
           name == "module_info")
  end

  defp resolve(_request, nil), do: :error

  defp resolve(request, "." <> name) do
    case Enum.find(local_functions(request), fn {_module, function} ->
           Atom.to_string(function) == name
         end) do
      {module, function} -> {:ok, module, function}
      nil -> :error
    end
  end

  defp resolve(request, tag) do
    {modules, [name]} = tag |> String.split(".") |> Enum.split(-1)
    module = expand_alias(request, Enum.join(modules, "."))

    case Enum.find(public_functions(module), &(Atom.to_string(&1) == name)) do
      nil -> :error
      function -> {:ok, module, function}
    end
  end

  defp components(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__components__, 0) do
      module.__components__()
    else
      %{}
    end
  end

  defp current_module(%{module: module}) when is_binary(module), do: existing_module(module)
  defp current_module(_request), do: nil

  defp enclosing_function(ancestors) do
    Enum.find_value(ancestors, :error, fn
      {kind, _meta, [head | _]} when kind in [:def, :defp] -> function_name(head)
      _ancestor -> nil
    end)
  end

  defp function_name({:when, _meta, [head | _]}), do: function_name(head)
  defp function_name({name, _meta, _args}) when is_atom(name), do: {:ok, name}
  defp function_name(_head), do: nil

  defp expand_alias(request, alias) do
    [first | rest] = String.split(alias, ".")

    aliased =
      Enum.find_value(request.aliases, fn
        {[segment], module} -> if Atom.to_string(segment) == first, do: module
        _alias -> nil
      end)

    case aliased do
      nil -> existing_module(Enum.join([first | rest], "."))
      module -> existing_atom(Enum.join([Atom.to_string(module) | rest], "."))
    end
  end

  defp existing_module("Elixir." <> _rest = module), do: existing_atom(module)
  defp existing_module(module), do: existing_atom("Elixir." <> module)

  defp existing_atom(module) do
    String.to_existing_atom(module)
  rescue
    ArgumentError -> nil
  end

  defp function_items(functions) do
    docs =
      for {module, _name} <- functions, uniq: true, into: %{} do
        {module, function_docs(module)}
      end

    for {module, name} <- functions do
      label = Atom.to_string(name)

      %{
        label: label,
        kind: :function,
        insert_text: label,
        detail: "#{inspect(module)}.#{label}/1"
      }
      |> put_documentation(docs[module][name])
    end
  end

  defp attribute_item(attr) do
    name = Atom.to_string(attr.name)
    value = if attr.type == :string, do: ~s("$1"), else: "{$1}"

    %{label: name, kind: :property, snippet: "#{name}=#{value}", detail: attr_detail(attr)}
    |> put_documentation(attr.doc)
  end

  defp assign_item(declaration, kind) do
    name = Atom.to_string(declaration.name)
    detail = if kind == "attr", do: "attr " <> attr_detail(declaration), else: "slot"

    %{label: name, kind: :variable, insert_text: name, detail: detail}
    |> put_documentation(declaration.doc)
  end

  defp attr_detail(attr), do: inspect(attr.type) <> required(attr)

  defp put_documentation(item, doc) when is_binary(doc), do: Map.put(item, :documentation, doc)
  defp put_documentation(item, _doc), do: item

  defp doc_line(module, function) do
    with {:docs_v1, _anno, _language, _format, _module_doc, _metadata, docs} <-
           Code.fetch_docs(module),
         {_key, anno, _signature, _doc, _metadata} <-
           List.keyfind(docs, {:function, function, 1}, 0) do
      :erl_anno.line(anno)
    else
      _ -> nil
    end
  end

  # Phoenix.Component adds the attributes and slots to the function docs. Docs
  # are only available for modules compiled to a BEAM file.
  defp function_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _language, _format, _module_doc, _metadata, docs} ->
        for {{:function, name, 1}, _anno, _signature, %{"en" => doc}, _metadata} <- docs,
            into: %{},
            do: {name, doc}

      _error ->
        %{}
    end
  end
end
