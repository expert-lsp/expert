defmodule Expert.CodeIntelligence.Completion.Modules do
  @moduledoc """
  Provides module completion candidates.

  Sources include the index, the toolchain, visible aliases, and definitions
  in the current document.

  Module names are written as `inspect/1` writes them, such as `"Enum"` and
  `":lists"`.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Matcher
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Expert.Search.Subject
  alias Expert.Toolchain
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @type compiled :: %{
          beam_path: Path.t(),
          kinds: [atom()],
          summary: String.t() | nil,
          application: atom() | String.t() | nil
        }

  @kinds [
    protocol: {"__protocol__", 1},
    implementation: {"__impl__", 1},
    struct: {"__struct__", 0},
    exception: {"exception", 1},
    behaviour: {"behaviour_info", 1}
  ]

  @doc """
  Returns the modules matching an alias being typed, such as `En` or
  `Enum.Em`.
  """
  @spec elixir(Context.t(), String.t(), keyword()) :: [struct()]
  def elixir(%Context{} = context, typed, opts \\ []) do
    structs_only? = Keyword.get(opts, :structs_only?, false)

    {aliases, parent_prefix, hint} =
      case String.split(typed, ".") do
        [hint] ->
          {aliased(context, hint), "", hint}

        segments ->
          {parent, [hint]} = Enum.split(segments, -1)
          parent = Context.expand_alias(context, Enum.map(parent, &String.to_atom/1))
          {[], inspect(parent) <> ".", hint}
      end

    prefix = parent_prefix <> String.slice(hint, 0, 1)

    nested =
      for name <- with_prefix(context.project, prefix) ++ defined(context, prefix),
          not String.starts_with?(name, ":"),
          segment = name |> String.replace_prefix(parent_prefix, "") |> String.split(".") |> hd(),
          alias_segment?(segment),
          Matcher.match?(segment, hint),
          uniq: true,
          do: {segment, parent_prefix <> segment}

    (aliases ++ nested)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.filter(fn {_name, full_name} ->
      not structs_only? or struct_or_parent?(context, full_name)
    end)
    |> Enum.flat_map(fn {name, full_name} -> List.wrap(candidate(context, name, full_name)) end)
  end

  @doc """
  Returns the Erlang modules matching `hint`, named with their leading colon.
  """
  @spec erlang(Context.t(), String.t()) :: [struct()]
  def erlang(%Context{} = context, hint) do
    for ":" <> name = full_name <- with_prefix(context.project, ":" <> String.slice(hint, 0, 1)),
        Matcher.match?(name, hint),
        candidate = candidate(context, full_name, full_name),
        do: candidate
  end

  @doc """
  Returns the indexed and toolchain modules whose names start with `prefix`.
  """
  @spec with_prefix(Project.t(), String.t()) :: [String.t()]
  def with_prefix(%Project{} = project, prefix) do
    indexed =
      case Store.prefix(project, prefix, type: :module, subtype: :definition) do
        {:ok, entries} -> Enum.map(entries, fn %Entry{subject: subject} -> name(subject) end)
        _error -> []
      end

    Enum.uniq(
      indexed ++ dependencies(project, prefix) ++ Toolchain.modules_with_prefix(project, prefix)
    )
  end

  # Erlang dependency modules come from the BEAM registry.
  defp dependencies(project, ":" <> prefix) do
    for name <- ModuleRegistry.with_prefix(project, prefix),
        module = Subject.module(name),
        String.starts_with?(module, ":"),
        do: module
  end

  defp dependencies(_project, _prefix), do: []

  @doc """
  Returns a compiled module's BEAM path, kinds, application, and summary.
  """
  @spec compiled(Project.t(), module() | String.t()) :: {:ok, compiled()} | :error
  def compiled(%Project{} = project, module) do
    name = name(module)

    case ModuleRegistry.lookup(project, registry_name(name)) do
      {:ok, %{beam_path: beam_path, exports: exports, application: application}} ->
        {:ok,
         %{
           beam_path: beam_path,
           kinds: kinds(name, exports.functions),
           summary: nil,
           application: application
         }}

      :error ->
        with {:ok, module} <- Toolchain.module(project, name) do
          {:ok,
           %{
             beam_path: module.beam_path,
             kinds: kinds(name, module.exports),
             summary: module.summary,
             application: module.application
           }}
        end
    end
  end

  @doc """
  Reads types, callbacks, struct fields, behaviours, and injected definitions
  from a compiled module.
  """
  @spec read(Project.t(), module() | String.t()) :: {:ok, map()} | :error
  def read(%Project{} = project, module) do
    with {:ok, %{beam_path: beam_path}} <- compiled(project, module) do
      Beams.read_module(beam_path)
    end
  end

  @doc """
  Returns whether a module defines a struct, or one of its nested modules
  does.
  """
  @spec struct_or_parent?(Context.t(), String.t()) :: boolean()
  def struct_or_parent?(%Context{} = context, full_name) do
    in_tree? = &(&1 == full_name or String.starts_with?(&1, full_name <> "."))

    Enum.any?(with_prefix(context.project, full_name), fn name ->
      in_tree?.(name) and struct?(context.project, name)
    end) or
      Enum.any?(context.definitions, fn {defined, definitions} ->
        is_list(definitions.struct_fields) and in_tree?.(inspect(defined))
      end)
  end

  defp struct?(project, name) do
    case compiled(project, name) do
      {:ok, compiled} -> :struct in compiled.kinds
      :error -> false
    end
  end

  defp kinds(name, functions) do
    kinds = for {kind, export} <- @kinds, export in functions, do: kind

    if String.starts_with?(name, "Mix.Tasks.") and {"run", 1} in functions,
      do: kinds ++ [:task],
      else: kinds
  end

  defp defined(context, prefix) do
    for {module, _definitions} <- context.definitions,
        name = inspect(module),
        String.starts_with?(name, prefix),
        do: name
  end

  defp aliased(context, hint) do
    for {[as], module} <- context.aliases,
        as != :__MODULE__,
        name = Atom.to_string(as),
        Matcher.match?(name, hint),
        do: {name, inspect(module)}
  end

  defp alias_segment?(<<first, rest::binary>>) when first in ?A..?Z,
    do: rest =~ ~r/^[A-Za-z0-9_]*$/

  defp alias_segment?(_segment), do: false

  defp candidate(context, name, full_name) do
    defined = Enum.find(context.definitions, fn {module, _} -> inspect(module) == full_name end)

    {kinds, summary, application} =
      case {defined, compiled(context.project, full_name)} do
        {{_module, definitions}, _compiled} ->
          kinds = if is_list(definitions.struct_fields), do: [:struct], else: []
          {kinds, definitions.summary, nil}

        {nil, {:ok, compiled}} ->
          {compiled.kinds, compiled.summary, compiled.application}

        {nil, :error} ->
          {[], nil, nil}
      end

    fields = [name: name, full_name: full_name, summary: summary, metadata: %{app: application}]

    candidate_for(kinds, fields)
  end

  defp candidate_for(kinds, fields) do
    cond do
      :protocol in kinds -> struct(Candidate.Protocol, fields)
      :implementation in kinds -> nil
      :exception in kinds -> struct(Candidate.Exception, fields)
      :struct in kinds -> struct(Candidate.Struct, fields)
      :behaviour in kinds -> struct(Candidate.Behaviour, fields)
      :task in kinds -> struct(Candidate.MixTask, fields)
      true -> struct(Candidate.Module, fields)
    end
  end

  defp name(module) when is_atom(module), do: inspect(module)
  defp name(module) when is_binary(module), do: module

  defp registry_name(":" <> erlang), do: erlang
  defp registry_name(elixir), do: "Elixir." <> elixir
end
