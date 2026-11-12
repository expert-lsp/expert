defmodule Expert.CodeIntelligence.Completion.Callables do
  @moduledoc """
  Function and macro candidates of a module, from the document's definitions
  when the document defines it and from its BEAM otherwise.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Definitions
  alias Expert.CodeIntelligence.Completion.Definitions.Definition
  alias Expert.CodeIntelligence.Completion.LocalsWithoutParens
  alias Expert.CodeIntelligence.Completion.Matcher
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Expert.Toolchain
  alias Forge.Formats
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @type candidate :: %Candidate.Function{} | %Candidate.Macro{}

  @builtins [{"__info__", 1}, {"module_info", 0}, {"module_info", 1}]
  @private [:defp, :defmacrop, :defguardp]
  @macros [:defmacro, :defmacrop, :defguard, :defguardp]

  @doc """
  Returns the functions and macros called as `module.name`.
  """
  @spec remote(Context.t(), module(), String.t(), keyword()) :: [candidate()]
  def remote(%Context{} = context, module, hint, opts \\ []) do
    context
    |> of_module(module, matcher(hint, opts), private?: module == context.module)
    |> sort()
  end

  @doc """
  Returns the functions and macros called without a module: special forms,
  imports and, inside a function, the current module's definitions.
  """
  @spec local(Context.t(), String.t(), keyword()) :: [candidate()]
  def local(%Context{} = context, hint, opts \\ []) do
    match? = matcher(hint, opts)

    special_forms = of_module(context, Kernel.SpecialForms, match?, builtins?: false)

    current =
      if context.module && context.function? do
        of_module(context, context.module, match?,
          builtins?: false,
          private?: true,
          macros_before: context.line
        )
      else
        []
      end

    imported =
      for {module, functions} <- context.imports,
          module != Kernel.SpecialForms,
          candidate <- of_module(context, module, match?, builtins?: false),
          {candidate.name, candidate.arity} in functions,
          do: candidate

    sort(special_forms) ++ sort(current) ++ sort(imported)
  end

  defp matcher(hint, opts) do
    if Keyword.get(opts, :exact?, false),
      do: &(&1 == hint),
      else: &Matcher.match?(&1, hint)
  end

  defp sort(candidates), do: Enum.sort_by(candidates, &{&1.name, &1.arity})

  defp of_module(context, module, match?, opts) do
    case Map.fetch(context.definitions, module) do
      {:ok, %Definitions{} = definitions} ->
        defined(context, module, definitions, match?, opts)

      :error ->
        compiled(context, module, match?, opts)
    end
  end

  defp defined(context, module, definitions, match?, opts) do
    private? = Keyword.get(opts, :private?, false)
    macros_before = Keyword.get(opts, :macros_before)

    for %Definition{} = definition <- definitions.definitions,
        private? or definition.kind not in @private,
        is_nil(macros_before) or definition.kind not in @macros or
          (is_integer(definition.line) and definition.line < macros_before),
        name = Atom.to_string(definition.name),
        match?.(name) do
      kind = if definition.kind in @macros, do: :macro, else: :function

      callable(context, kind,
        name: name,
        arity: definition.arity,
        argument_names: definition.arguments,
        origin: inspect(module),
        visibility: if(definition.kind in @private, do: :private, else: :public),
        spec: definition.spec,
        summary: definition.summary,
        metadata: definition.metadata
      )
    end
  end

  defp compiled(context, module, match?, opts) do
    indexed = indexed(context.project, module)

    builtins =
      if indexed != [] and Keyword.get(opts, :builtins?, true),
        do: for({name, arity} <- @builtins, do: {:function, name, arity, %{}, nil}),
        else: []

    for {kind, name, arity, metadata, app} <- indexed ++ builtins,
        match?.(name) do
      callable(context, kind,
        name: name,
        arity: arity,
        argument_names: Map.get(metadata, :arguments) || Enum.map(1..arity//1, &"arg_#{&1}"),
        origin: inspect(module),
        visibility: :public,
        spec: "",
        metadata: metadata |> Map.take([:deprecated]) |> Map.put(:app, app)
      )
    end
  end

  @doc """
  Returns the public functions and macros the index has for `module`.
  """
  @spec exports(Project.t(), module()) ::
          {:ok, %{functions: [{String.t(), arity()}], macros: [{String.t(), arity()}]}} | :error
  def exports(%Project{} = project, module) do
    case indexed(project, module) do
      [] ->
        :error

      definitions ->
        {:ok,
         %{
           functions: for({:function, name, arity, _, _} <- definitions, do: {name, arity}),
           macros: for({:macro, name, arity, _, _} <- definitions, do: {name, arity})
         }}
    end
  end

  # Elixir, OTP and Erlang dependencies aren't indexed, so we read them from
  # their BEAMs. Nested modules' definitions share the prefix; their names
  # start with the nested module's name.
  defp indexed(project, module) do
    name = Formats.module(module)
    prefix = name <> "."

    entries =
      case Store.prefix(project, prefix, type: :_, subtype: :definition) do
        {:ok, [_ | _] = entries} ->
          entries

        _missing ->
          Toolchain.definitions(project, name)
      end

    definitions =
      for %Entry{type: {kind, visibility}} = entry <- entries,
          kind in [:function, :macro],
          visibility in [:public, :delegate],
          {name, arity} <- List.wrap(name_and_arity(entry.subject, prefix)),
          do: {kind, name, arity, entry.metadata || %{}, entry.application}

    case Enum.uniq_by(definitions, fn {kind, name, arity, _, _} -> {kind, name, arity} end) do
      [] -> dependency(project, name)
      definitions -> definitions
    end
  end

  # Erlang dependencies are only known by the exports the registry reads from
  # their BEAMs.
  defp dependency(project, ":" <> name) do
    case ModuleRegistry.lookup(project, name) do
      {:ok, %{exports: exports, application: application}} ->
        for export <- exports.functions,
            export not in @builtins,
            {name, arity} = export,
            do: {:function, name, arity, %{}, application}

      :error ->
        []
    end
  end

  defp dependency(_project, _name), do: []

  defp name_and_arity(subject, prefix) when is_binary(subject) do
    rest = String.replace_prefix(subject, prefix, "")

    with [_ | _] = slashes <- :binary.matches(rest, "/"),
         {at, 1} = List.last(slashes),
         name when name != "" <- binary_part(rest, 0, at),
         false <- name =~ ~r/^[A-Z]/,
         {arity, ""} <- rest |> binary_part(at + 1, byte_size(rest) - at - 1) |> Integer.parse() do
      {name, arity}
    else
      _ -> nil
    end
  end

  defp name_and_arity(_subject, _prefix), do: nil

  defp callable(context, kind, fields) do
    parens? =
      not LocalsWithoutParens.without_parens?(
        context.locals_without_parens,
        fields[:name],
        fields[:arity]
      )

    candidate = if kind == :macro, do: Candidate.Macro, else: Candidate.Function
    struct(candidate, [type: kind, parens?: parens?] ++ fields)
  end
end
