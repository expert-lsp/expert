defmodule Forge.Ast.Analysis.State do
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Require
  alias Forge.Ast.Analysis.Scope
  alias Forge.Ast.Analysis.Use
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  defstruct [:document, scopes: [], use_imports: %{}, visited: %{}]

  def new(%Document{} = document, use_imports \\ %{}) do
    state = %__MODULE__{document: document, use_imports: use_imports}

    scope =
      document
      |> global_range()
      |> Scope.global()

    push_scope(state, scope)
  end

  def current_scope(%__MODULE__{scopes: [scope | _]}), do: scope

  def current_module(%__MODULE__{} = state) do
    current_scope(state).module
  end

  def push_scope(%__MODULE__{} = state, %Scope{} = scope) do
    Map.update!(state, :scopes, &[scope | &1])
  end

  def push_scope(%__MODULE__{} = state, id, %Range{} = range, module) when is_list(module) do
    scope =
      state
      |> current_scope()
      |> Scope.new(id, range, module)

    push_scope(state, scope)
  end

  def push_scope_for(%__MODULE__{} = state, quoted, %Range{} = range, module) do
    module = module || current_module(state)

    id = Analysis.scope_id(quoted)
    push_scope(state, id, range, module)
  end

  def push_scope_for(%__MODULE__{} = state, quoted, module) do
    range = get_range(quoted, state.document)
    push_scope_for(state, quoted, range, module)
  end

  def maybe_push_scope_for(%__MODULE__{} = state, quoted) do
    case get_range(quoted, state.document) do
      %Range{} = range ->
        push_scope_for(state, quoted, range, nil)

      nil ->
        state
    end
  end

  def pop_scope(%__MODULE__{scopes: [scope | rest]} = state) do
    %__MODULE__{state | scopes: rest, visited: Map.put(state.visited, scope.id, scope)}
  end

  def push_alias(%__MODULE__{} = state, %Alias{} = alias) do
    update_current_scope(state, fn %Scope{} = scope ->
      [prefix | rest] = alias.module

      alias =
        case Scope.fetch_alias_with_prefix(scope, prefix) do
          {:ok, %Alias{} = existing_alias} ->
            %Alias{alias | module: existing_alias.module ++ rest}

          :error ->
            alias
        end

      Map.update!(scope, :aliases, &[alias | &1])
    end)
  end

  def push_import(%__MODULE__{} = state, %Import{} = import) do
    update_current_scope(state, fn %Scope{} = scope ->
      Map.update!(scope, :imports, &[import | &1])
    end)
  end

  def push_require(%__MODULE__{} = state, %Require{} = require) do
    update_current_scope(state, fn %Scope{} = scope ->
      Map.update!(scope, :requires, &[require | &1])
    end)
  end

  def push_use(%__MODULE__{} = state, %Use{} = use) do
    update_current_scope(state, fn %Scope{} = scope ->
      scope = Map.update!(scope, :uses, &[use | &1])

      if is_list(use.imported_mfas) do
        %{scope | latest_expanded_use: use}
      else
        scope
      end
    end)
  end

  defp update_current_scope(%__MODULE__{} = state, fun) do
    update_in(state, [Access.key(:scopes), Access.at!(0)], fn %Scope{} = scope ->
      fun.(scope)
    end)
  end

  # if there is no code after a stab operator, then the end position
  # it gives us can be in the middle of the line, as it's derived from
  # the start of some entity on the last line. So we increment the line
  # by one, and that should be the end of the stab block
  defp get_range({:->, _, _} = quoted, %Document{} = document) do
    start_pos = get_start_position(quoted)

    case Sourceror.get_end_position(quoted, line: -1, column: -1) do
      [line: -1, column: -1] ->
        nil

      [line: line, column: 1] ->
        Range.new(
          Position.new(document, start_pos[:line], start_pos[:column]),
          Position.new(document, line + 1, 1)
        )

      [line: line, column: _] ->
        Range.new(
          Position.new(document, start_pos[:line], start_pos[:column]),
          Position.new(document, line + 1, 1)
        )
    end
  end

  defp get_range(quoted, %Document{} = document) do
    start_pos = get_start_position(quoted)

    case Sourceror.get_end_position(quoted, line: -1, column: -1) do
      [line: -1, column: -1] ->
        nil

      [line: end_line, column: end_column] ->
        Range.new(
          Position.new(document, start_pos[:line], start_pos[:column]),
          Position.new(document, end_line, end_column)
        )
    end
  end

  defp global_range(%Document{} = document) do
    num_lines = Document.size(document)

    Range.new(
      Position.new(document, 1, 1),
      Position.new(document, num_lines + 1, 1)
    )
  end

  defp get_start_position({_, metadata, _} = ast) do
    case Keyword.fetch(metadata, :do) do
      {:ok, [line: line, column: column]} ->
        # add 2 to position us after the do keyword
        [line: line, column: column + 2]

      _ ->
        Sourceror.get_start_position(ast)
    end
  end

  defp get_start_position({block_meta, _rest}) do
    case Sourceror.get_start_position(block_meta) do
      [line: line, column: column] ->
        [line: line, column: column + 2]

      other ->
        other
    end
  end
end
