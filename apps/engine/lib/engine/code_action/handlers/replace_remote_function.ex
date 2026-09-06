defmodule Engine.CodeAction.Handlers.ReplaceRemoteFunction do
  @behaviour Engine.CodeAction.Handler

  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Parser
  alias Engine.CodeAction
  alias Engine.Modules
  alias Forge.Ast
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Edit
  alias Forge.Document.Range
  alias GenLSP.Enumerations.CodeActionKind
  alias Sourceror.Zipper

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{}, diagnostics, _opts \\ []) do
    Enum.flat_map(diagnostics, fn %Diagnostic{} = diagnostic ->
      with {:ok, module, function, arity, line_number} <- extract_function_and_line(diagnostic),
           {:ok, suggestions} <- prepare_suggestions(module, function, arity) do
        to_code_actions(doc, line_number, module, function, suggestions)
      else
        _ ->
          []
      end
    end)
  end

  @impl CodeAction.Handler
  def kinds do
    [CodeActionKind.quick_fix()]
  end

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  @spec to_code_actions(Document.t(), non_neg_integer(), module(), String.t(), [atom()]) ::
          [Forge.CodeAction.t()]
  defp to_code_actions(%Document{} = doc, line_number, module, function, suggestions) do
    suggestions
    |> Enum.reduce([], fn suggestion, acc ->
      case apply_transform(doc, line_number, module, function, suggestion) do
        {:ok, [_ | _] = edits} ->
          changes = Changes.new(doc, edits)

          code_action =
            Forge.CodeAction.new(
              doc.uri,
              "Rename to #{suggestion}",
              CodeActionKind.quick_fix(),
              changes
            )

          [code_action | acc]

        {:ok, []} ->
          acc

        :error ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @spec apply_transform(Document.t(), non_neg_integer(), module(), String.t(), atom()) ::
          {:ok, [Edit.t()]} | :error
  defp apply_transform(%Document{} = doc, line_number, module, function, suggestion) do
    {:ok, doc, analysis} = Document.Store.fetch(doc.uri, :analysis)
    function_atom = String.to_atom(function)
    position = Document.Position.new(doc, line_number, 0)

    doc
    |> Ast.traverse_line(line_number, [], fn
      %Zipper{node: {{:., _, [{:__aliases__, _, module_alias}, ^function_atom]}, _, _}} = zipper,
      patches ->
        if Engine.Analyzer.expand_alias(module_alias, analysis, position) == {:ok, module} or
             alias_matches?(doc, module_alias, module, line_number) do
          patch = Sourceror.Patch.rename_call(zipper.node, suggestion)
          {zipper, [patch | patches]}
        else
          {zipper, patches}
        end

      %Zipper{node: {{:., _, [{:__MODULE__, _, _}, ^function_atom]}, _, _}} = zipper, patches ->
        case Engine.Analyzer.current_module(analysis, position) do
          {:ok, ^module} ->
            patch = Sourceror.Patch.rename_call(zipper.node, suggestion)
            {zipper, [patch | patches]}

          _ ->
            {zipper, patches}
        end

      %Zipper{node: {{:., _, [{:__block__, _, [^module]}, ^function_atom]}, _, _}} = zipper,
      patches ->
        # this is an erlang call :ets.insert(...)
        patch = Sourceror.Patch.rename_call(zipper.node, suggestion)

        {zipper, [patch | patches]}

      zipper, patches ->
        {zipper, patches}
    end)
    |> case do
      {:ok, _zipper, patches} ->
        Ast.patches_to_edits(doc, patches)

      _ ->
        :error
    end
  end

  defp extract_function_and_line(%Diagnostic{} = diagnostic) do
    with {:ok, module, function, arity} <- extract_function(diagnostic.message) do
      {:ok, module, function, arity, diagnostic.range.start.line}
    end
  end

  @function_re ~r/(warning: |function )?([^\/]+)\/(\d+) is undefined or private. Did you mean:.*/
  defp extract_function(message) do
    result =
      with [[_, _, module_and_function, arity]] <- Regex.scan(@function_re, message),
           {:ok, module, function_name} <- separate_module_from_function(module_and_function) do
        {:ok, module, function_name, String.to_integer(arity)}
      end

    result
  end

  defp separate_module_from_function(module_and_function) do
    module_and_function
    |> String.split(".")
    |> List.pop_at(-1)
    |> case do
      {function_name, [_ | _] = module_alias} ->
        {:ok, alias_to_module(module_alias), function_name}

      _ ->
        :error
    end
  end

  defp alias_to_module([":" <> erlang_alias]) do
    String.to_atom(erlang_alias)
  end

  defp alias_to_module(module_alias) do
    Module.concat(module_alias)
  end

  defp alias_matches?(document, [alias] = module_alias, module, line) when is_atom(alias) do
    position = {line, 1}
    metadata = Parser.parse_string(Document.to_string(document), true, false, position)
    env = Metadata.get_cursor_env(metadata, position)

    {Module.concat(module_alias), module} in env.aliases
  end

  defp alias_matches?(_document, _module_alias, _module, _line), do: false

  @function_threshold 0.77
  @max_suggestions 5
  defp prepare_suggestions(module, function, arity) do
    with {:ok, module_functions} <- Modules.fetch_functions(module) do
      suggestions =
        for {module_function, ^arity} <- module_functions,
            distance = module_function |> Atom.to_string() |> String.jaro_distance(function),
            distance >= @function_threshold do
          {distance, module_function}
        end
        |> Enum.sort(:desc)
        |> Enum.take(@max_suggestions)
        |> Enum.map(fn {_distance, module_function} -> module_function end)

      {:ok, suggestions}
    end
  end
end
