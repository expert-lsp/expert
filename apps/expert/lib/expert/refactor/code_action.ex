defmodule Expert.Refactor.CodeAction do
  @moduledoc """
  Code action handler for AST refactorings powered by `Expert.Refactor`.
  """

  alias Expert.EngineApi
  alias Expert.Refactor
  alias Forge.CodeAction
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Diff
  alias Forge.Document.Range
  alias Forge.Project
  alias GenLSP.Enumerations

  require Logger

  @spec actions(
          Project.t() | nil,
          Document.t(),
          Range.t(),
          list(),
          [String.t()] | :all,
          integer() | :all,
          keyword()
        ) :: [CodeAction.t()]
  def actions(
        project,
        %Document{} = doc,
        %Range{} = range,
        _diagnostics,
        kinds,
        trigger_kind,
        opts \\ []
      ) do
    if handle_kinds?(kinds) and handle_trigger_kind?(trigger_kind) do
      with {:ok, target} <- line_or_selection(doc, range),
           {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)) do
        zipper = Sourceror.Zipper.zip(ast)
        refactorings = Refactor.list(zipper, target)

        if Keyword.get(opts, :defer_edits?, false) do
          Enum.map(refactorings, &to_deferred_action(doc, range, &1))
        else
          execute_all(project, doc, zipper, target, refactorings)
        end
      else
        _ -> []
      end
    else
      []
    end
  rescue
    _ ->
      []
  end

  @doc """
  Computes the edits for a single refactoring previously listed with `defer_edits?: true`, as
  part of the `codeAction/resolve` flow.
  """
  @spec resolve(Project.t() | nil, Document.t(), Range.t(), String.t() | module()) ::
          {:ok, Changes.t()} | :error
  def resolve(project, %Document{} = doc, %Range{} = range, module_name) do
    with {:ok, target} <- line_or_selection(doc, range),
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)),
         {:ok, refactoring} <-
           ast |> Sourceror.Zipper.zip() |> Refactor.execute(target, module_name) do
      {:ok, ast_to_changes(doc, refactoring.refactored, sourceror_opts(project, doc))}
    else
      _ -> :error
    end
  end

  def kinds, do: [Enumerations.CodeActionKind.refactor()]

  def trigger_kind, do: :all

  defp handle_kinds?(:all), do: true
  defp handle_kinds?(kinds) when is_list(kinds), do: kinds -- kinds() != kinds
  defp handle_kinds?(_), do: true

  defp handle_trigger_kind?(:all), do: true
  defp handle_trigger_kind?(_), do: true

  defp to_deferred_action(%Document{} = doc, %Range{} = range, refactoring) do
    data = CodeAction.to_refactor_data(doc.uri, doc.version, range, refactoring.module)
    CodeAction.deferred(doc.uri, refactoring.title, refactoring.kind, data)
  end

  defp execute_all(_project, _doc, _zipper, _target, []), do: []

  defp execute_all(project, doc, zipper, target, refactorings) do
    opts = sourceror_opts(project, doc)
    Enum.flat_map(refactorings, &execute_eagerly(doc, zipper, target, &1, opts))
  end

  defp execute_eagerly(doc, zipper, target, refactoring, sourceror_opts) do
    case Refactor.execute(zipper, target, refactoring.module) do
      {:ok, executed} ->
        [
          CodeAction.new(
            doc.uri,
            executed.title,
            executed.kind,
            ast_to_changes(doc, executed.refactored, sourceror_opts)
          )
        ]

      :error ->
        []
    end
  rescue
    error ->
      Logger.error(
        "refactor: #{inspect(refactoring.module)}: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      []
  end

  defp line_or_selection(_, %{
         start: %{line: line, character: char},
         end: %{line: line, character: char}
       }),
       do: {:ok, line}

  defp line_or_selection(doc, %{start: start} = range) do
    doc
    |> Document.fragment(range.start, range.end)
    |> Sourceror.parse_string(line: start.line, column: start.character)
  end

  defp sourceror_opts(project, doc) do
    opts =
      case EngineApi.formatter_opts(project, doc.path) do
        opts when is_list(opts) -> opts
        _ -> []
      end

    Keyword.reject(
      [
        locals_without_parens: opts[:locals_without_parens] || [],
        line_length: opts[:line_length]
      ],
      fn {_k, v} -> is_nil(v) end
    )
  end

  defp ast_to_changes(doc, ast, sourceror_opts) do
    ast
    |> Sourceror.to_string(sourceror_opts)
    |> then(&Diff.diff(doc, &1))
    |> then(&Changes.new(doc, &1))
  end
end
