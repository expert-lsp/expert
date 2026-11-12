defmodule Expert.CodeIntelligence.Completion.Context do
  @moduledoc """
  What the code at the cursor can refer to: its module, aliases, imports and
  the modules the document defines.
  """

  alias Expert.CodeIntelligence.Completion.Callables
  alias Expert.CodeIntelligence.Completion.Definitions
  alias Expert.CodeIntelligence.Completion.LocalsWithoutParens
  alias Expert.Search.Indexer.Analysis.Aliases
  alias Expert.Search.Indexer.Analysis.Imports
  alias Expert.Search.Indexer.Analyzer
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Project

  defstruct [
    :project,
    :module,
    :line,
    :in_scope,
    cursor_path: [],
    function?: false,
    aliases: %{},
    imports: %{},
    definitions: %{},
    locals_without_parens: []
  ]

  @type t :: %__MODULE__{
          project: Project.t(),
          module: module() | nil,
          line: pos_integer(),
          in_scope: Aliases.in_scope(),
          cursor_path: [Macro.t()],
          function?: boolean(),
          aliases: %{[atom()] => module()},
          imports: %{module() => MapSet.t({String.t(), arity()})},
          definitions: %{module() => Definitions.t()},
          locals_without_parens: LocalsWithoutParens.t()
        }

  @definition_forms [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]

  @spec new(Env.t(), Analysis.t()) :: t()
  def new(%Env{} = env, %Analysis{} = document_analysis) do
    in_scope = Aliases.in_scope(env.analysis, env.position)
    {scope_aliases, _line} = in_scope

    aliases =
      for %{as: as} <- scope_aliases,
          is_list(as),
          {:ok, module} <- [Aliases.fetch(in_scope, as)],
          into: %{},
          do: {as, module}

    imports =
      env.analysis
      |> Imports.at(env.position, &Callables.exports(env.project, &1))
      |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
      |> Map.new(fn {module, functions} -> {module, MapSet.new(functions)} end)
      |> with_kernel(env.project)

    definitions =
      if document_analysis.ast,
        do: Definitions.in_document(document_analysis),
        else: Definitions.in_document(env.analysis)

    cursor_path = cursor_path(env)

    %__MODULE__{
      project: env.project,
      module: Map.get(aliases, [:__MODULE__]),
      line: env.position.line,
      in_scope: in_scope,
      cursor_path: cursor_path,
      function?: Enum.any?(cursor_path, &match?({form, _, _} when form in @definition_forms, &1)),
      aliases: aliases,
      imports: imports,
      definitions: definitions,
      locals_without_parens: LocalsWithoutParens.for_project(env.project)
    }
  end

  @spec expand_alias(t(), [atom()]) :: module()
  def expand_alias(%__MODULE__{} = context, segments) do
    case Analyzer.expand_alias_with(segments, context.in_scope) do
      {:ok, module} -> module
      :error -> Module.concat(segments)
    end
  end

  # A reserved word before the cursor, such as `in`, doesn't parse as a
  # fragment. As an identifier prefix it does.
  defp cursor_path(%Env{} = env) do
    case Ast.cursor_path(env.analysis, env.position) do
      [] ->
        fragment = Document.fragment(env.document, env.position) <> "_"

        case Code.Fragment.container_cursor_to_quoted(fragment) do
          {:ok, quoted} -> quoted |> Macro.path(&match?({:__cursor__, _, _}, &1)) |> List.wrap()
          _error -> []
        end

      path ->
        path
    end
  end

  # An analysis without scopes, such as one of a lone operator, has no
  # imports, but Kernel is always imported.
  defp with_kernel(imports, project) when map_size(imports) == 0 do
    case Callables.exports(project, Kernel) do
      {:ok, exports} -> %{Kernel => MapSet.new(exports.functions ++ exports.macros)}
      :error -> imports
    end
  end

  defp with_kernel(imports, _project), do: imports
end
