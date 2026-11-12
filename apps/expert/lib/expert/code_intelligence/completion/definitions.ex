defmodule Expert.CodeIntelligence.Completion.Definitions do
  @moduledoc """
  The modules a document defines, with their functions, macros and
  behaviours, read from the document's AST so they complete before the
  document compiles.
  """

  alias Expert.Search.Indexer.ArgumentNames
  alias Forge.Ast.Analysis

  defmodule Definition do
    @moduledoc false
    defstruct [:kind, :name, :arity, :arguments, :summary, :spec, :line, metadata: %{}]

    @type kind ::
            :def
            | :defp
            | :defmacro
            | :defmacrop
            | :defguard
            | :defguardp
            | :defdelegate
            | :callback
            | :macrocallback
            | :type
            | :typep
            | :opaque
    @type t :: %__MODULE__{
            kind: kind(),
            name: atom(),
            arity: arity(),
            arguments: [String.t()],
            summary: String.t() | nil,
            spec: String.t(),
            line: pos_integer() | nil,
            metadata: map()
          }
  end

  defstruct [
    :module,
    :summary,
    behaviours: [],
    struct_fields: nil,
    attributes: [],
    definitions: [],
    callbacks: [],
    types: []
  ]

  @type t :: %__MODULE__{
          module: module(),
          summary: String.t() | nil,
          behaviours: [Macro.t()],
          struct_fields: [atom()] | nil,
          attributes: [{atom(), pos_integer() | nil}],
          definitions: [Definition.t()],
          callbacks: [Definition.t()],
          types: [Definition.t()]
        }

  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @modules [:defmodule, :defprotocol]

  @spec in_document(Analysis.t()) :: %{module() => t()}
  def in_document(%Analysis{ast: nil}), do: %{}

  def in_document(%Analysis{ast: ast}) do
    ast |> walk(nil, %{}) |> Map.new(fn {module, defined} -> {module, finish(defined)} end)
  end

  defp walk({form, _meta, [name, [{_do, body} | _]]}, parent, modules)
       when form in @modules do
    case module_name(name, parent) do
      {:ok, module} ->
        defined = Map.get(modules, module, %__MODULE__{module: module})
        {defined, modules} = body |> statements() |> collect(module, defined, %{}, modules)
        Map.put(modules, module, defined)

      :error ->
        modules
    end
  end

  defp walk({_form, _meta, args}, parent, modules) when is_list(args),
    do: Enum.reduce(args, modules, &walk(&1, parent, &2))

  defp walk({left, right}, parent, modules),
    do: walk(right, parent, walk(left, parent, modules))

  defp walk(list, parent, modules) when is_list(list),
    do: Enum.reduce(list, modules, &walk(&1, parent, &2))

  defp walk(_other, _parent, modules), do: modules

  defp module_name({:__aliases__, _meta, [{:__MODULE__, _, _} | rest]}, parent)
       when not is_nil(parent),
       do: concat(parent, rest)

  defp module_name({:__aliases__, _meta, segments}, nil), do: concat(nil, segments)
  defp module_name({:__aliases__, _meta, segments}, parent), do: concat(parent, segments)
  defp module_name({:__block__, _meta, [module]}, _parent) when is_atom(module), do: {:ok, module}
  defp module_name(_name, _parent), do: :error

  defp concat(parent, segments) do
    if Enum.all?(segments, &is_atom/1) do
      {:ok, Module.concat([parent | segments] -- [nil])}
    else
      :error
    end
  end

  defp statements({:__block__, _meta, statements}) when is_list(statements), do: statements
  defp statements(statement), do: [statement]

  # Attributes like `@doc` and `@spec` apply to the next definition.
  defp collect([], _module, defined, _pending, modules), do: {defined, modules}

  defp collect([statement | rest], module, defined, pending, modules) do
    {defined, pending, modules} = statement(statement, module, defined, pending, modules)
    collect(rest, module, defined, pending, modules)
  end

  defp statement({:@, meta, [{name, _, [value]}]}, _module, defined, pending, modules)
       when is_atom(name) do
    defined = %{defined | attributes: [{name, Keyword.get(meta, :line)} | defined.attributes]}

    case name do
      :moduledoc ->
        {%{defined | summary: summary(value)}, pending, modules}

      :behaviour ->
        {%{defined | behaviours: [value | defined.behaviours]}, pending, modules}

      :doc ->
        {defined, Map.put(pending, :doc, value), modules}

      :typedoc ->
        {defined, Map.put(pending, :typedoc, value), modules}

      :spec ->
        {defined, Map.update(pending, :specs, [value], &[value | &1]), modules}

      :deprecated ->
        {defined, Map.put(pending, :deprecated, literal(value)), modules}

      kind when kind in [:callback, :macrocallback] ->
        callbacks = List.wrap(typespec(kind, meta, value, Map.get(pending, :doc)))

        {%{defined | callbacks: callbacks ++ defined.callbacks}, Map.delete(pending, :doc),
         modules}

      kind when kind in [:type, :typep, :opaque] ->
        types = List.wrap(typespec(kind, meta, value, Map.get(pending, :typedoc)))
        {%{defined | types: types ++ defined.types}, Map.delete(pending, :typedoc), modules}

      _other ->
        {defined, pending, modules}
    end
  end

  defp statement({form, _, args}, _module, defined, pending, modules)
       when form in [:defstruct, :defexception] do
    fields =
      case args do
        [fields] when is_list(fields) -> Enum.flat_map(fields, &field/1)
        _ -> []
      end

    {%{defined | struct_fields: fields}, pending, modules}
  end

  defp statement({kind, meta, [head | _]}, _module, defined, pending, modules)
       when kind in @definitions do
    case definitions(kind, meta, head, pending) do
      [_ | _] = definitions ->
        {%{defined | definitions: Enum.reverse(definitions, defined.definitions)}, %{}, modules}

      [] ->
        {defined, pending, modules}
    end
  end

  defp statement({form, _, _} = nested, module, defined, pending, modules)
       when form in @modules do
    {defined, pending, walk(nested, module, modules)}
  end

  defp statement(_statement, _module, defined, pending, modules),
    do: {defined, pending, modules}

  defp definitions(kind, meta, {:when, _, [head | _]}, pending),
    do: definitions(kind, meta, head, pending)

  defp definitions(kind, meta, {name, _, args}, pending) when is_atom(name) do
    args = if is_list(args), do: args, else: []

    metadata =
      case pending do
        %{deprecated: deprecated} when is_binary(deprecated) -> %{deprecated: deprecated}
        %{doc: doc} -> if literal(doc) == false, do: %{hidden: true}, else: %{}
        _ -> %{}
      end

    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    summary = summary(Map.get(pending, :doc))
    spec = pending |> Map.get(:specs, []) |> Enum.reverse() |> Enum.map_join("\n", &source/1)

    for arity <- (length(args) - defaults)..length(args) do
      %Definition{
        kind: kind,
        name: name,
        arity: arity,
        arguments: ArgumentNames.for_arity(args, arity),
        summary: summary,
        spec: spec,
        line: Keyword.get(meta, :line),
        metadata: metadata
      }
    end
  end

  defp definitions(_kind, _meta, _head, _pending), do: []

  defp typespec(kind, meta, {:when, _, [spec | _]}, doc), do: typespec(kind, meta, spec, doc)

  defp typespec(kind, meta, {:"::", _, [{name, _, args}, _definition]} = spec, doc)
       when is_atom(name) do
    args = if is_list(args), do: args, else: []

    %Definition{
      kind: kind,
      name: name,
      arity: length(args),
      arguments: args |> Enum.with_index(1) |> Enum.map(&parameter_name/1),
      summary: summary(doc),
      spec: source(spec),
      line: Keyword.get(meta, :line)
    }
  end

  defp typespec(_kind, _meta, _spec, _doc), do: nil

  defp parameter_name({{:"::", _, [{name, _, context}, _type]}, _index})
       when is_atom(name) and is_atom(context),
       do: Atom.to_string(name)

  defp parameter_name({{name, _, context}, _index}) when is_atom(name) and is_atom(context),
    do: Atom.to_string(name)

  defp parameter_name({_parameter, index}), do: "arg_#{index}"

  # Clauses after the first one share the first one's arguments and docs.
  defp finish(%__MODULE__{} = defined) do
    definitions =
      defined.definitions
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.name, &1.arity})

    %{
      defined
      | definitions: definitions,
        behaviours: Enum.reverse(defined.behaviours),
        attributes: Enum.reverse(defined.attributes),
        callbacks: Enum.reverse(defined.callbacks),
        types: Enum.reverse(defined.types)
    }
  end

  defp summary(nil), do: nil

  defp summary(doc) do
    case literal(doc) do
      doc when is_binary(doc) ->
        doc |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> String.trim()

      _other ->
        nil
    end
  end

  defp field({key, _default}), do: field(key)
  defp field({:__block__, _, [key]}) when is_atom(key), do: [key]
  defp field(key) when is_atom(key), do: [key]
  defp field(_field), do: []

  defp literal({:__block__, _, [value]}), do: literal(value)
  defp literal(value) when is_binary(value) or is_boolean(value), do: value
  defp literal(_value), do: nil

  # Literals in the analysis AST are wrapped in blocks, which print oddly.
  defp source(ast) do
    ast
    |> Macro.prewalk(fn
      {:__block__, _, [literal]} when not is_tuple(literal) or tuple_size(literal) != 3 ->
        literal

      node ->
        node
    end)
    |> Macro.to_string()
  end
end
