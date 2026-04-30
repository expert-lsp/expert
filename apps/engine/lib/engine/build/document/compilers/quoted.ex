defmodule Engine.Build.Document.Compilers.Quoted do
  import Engine.Build.CaptureIO, only: [capture_io: 2]

  alias Elixir.Features
  alias Engine.Build
  alias Engine.ModuleMappings
  alias Forge.Ast
  alias Forge.Document

  def compile(%Document{} = document, quoted_ast, compiler_name) do
    prepare_compile(document.path)

    quoted_ast =
      if document.language_id == "elixir-script" do
        wrap_top_level_forms(quoted_ast)
      else
        quoted_ast
      end

    {status, diagnostics} =
      if Features.with_diagnostics?() do
        do_compile(quoted_ast, document)
      else
        do_compile_and_capture_io(quoted_ast, document)
      end

    {status, Enum.map(diagnostics, &replace_source(&1, compiler_name))}
  end

  defp do_compile(quoted_ast, document) do
    old_modules = ModuleMappings.modules_in_file(document.path)

    case compile_quoted_with_diagnostics(quoted_ast, document.path) do
      {{:ok, modules}, []} ->
        purge_removed_modules(old_modules, modules)
        {:ok, []}

      {{:ok, modules}, all_errors_and_warnings} ->
        purge_removed_modules(old_modules, modules)

        diagnostics =
          document
          |> Build.Error.diagnostics_from_mix(all_errors_and_warnings)
          |> Build.Error.refine_diagnostics()

        {:ok, diagnostics}

      {{:exception, exception, stack, quoted_ast}, all_errors_and_warnings} ->
        converted = Build.Error.error_to_diagnostic(document, exception, stack, quoted_ast)
        maybe_diagnostics = Build.Error.diagnostics_from_mix(document, all_errors_and_warnings)

        diagnostics =
          [converted | maybe_diagnostics]
          |> Enum.reverse()
          |> Build.Error.refine_diagnostics()

        {:error, diagnostics}
    end
  end

  defp do_compile_and_capture_io(quoted_ast, document) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO: remove this function once we drop support for Elixir 1.14
    old_modules = ModuleMappings.modules_in_file(document.path)
    compile = fn -> safe_compile_quoted(quoted_ast, document.path) end

    case capture_io(:stderr, compile) do
      {captured_messages, {:error, {:exception, {exception, _inner_stack}, stack}}} ->
        error = Build.Error.error_to_diagnostic(document, exception, stack, [])
        diagnostics = Build.Error.message_to_diagnostic(document, captured_messages)

        {:error, [error | diagnostics]}

      {captured_messages, {:exception, exception, stack, quoted_ast}} ->
        error = Build.Error.error_to_diagnostic(document, exception, stack, quoted_ast)
        diagnostics = Build.Error.message_to_diagnostic(document, captured_messages)
        refined = Build.Error.refine_diagnostics([error | diagnostics])

        {:error, refined}

      {"", {:ok, modules}} ->
        purge_removed_modules(old_modules, modules)
        {:ok, []}

      {captured_warnings, {:ok, modules}} ->
        purge_removed_modules(old_modules, modules)

        diagnostics =
          document
          |> Build.Error.message_to_diagnostic(captured_warnings)
          |> Build.Error.refine_diagnostics()

        {:ok, diagnostics}
    end
  end

  defp prepare_compile(path) do
    if Engine.Mix.loaded?() do
      # If we're compiling a mix.exs file, the after compile callback from
      # `use Mix.Project` will blow up if we add the same project to the project stack
      # twice. Preemptively popping it prevents that error from occurring.
      if Path.basename(path) == "mix.exs" do
        Engine.with_lock(Engine.Mix.StackMutation, fn ->
          Mix.ProjectStack.pop()
        end)
      end

      Mix.Task.run(:loadconfig)
    else
      :ok
    end
  end

  @dialyzer {:nowarn_function, compile_quoted_with_diagnostics: 2}

  defp compile_quoted_with_diagnostics(quoted_ast, path) do
    # Using apply to prevent a compile warning on elixir < 1.15
    # credo:disable-for-next-line
    apply(Code, :with_diagnostics, [fn -> safe_compile_quoted(quoted_ast, path) end])
  end

  defp safe_compile_quoted(quoted_ast, path) do
    {:ok, Code.compile_quoted(quoted_ast, path)}
  rescue
    exception ->
      {filled_exception, stack} = Exception.blame(:error, exception, __STACKTRACE__)
      {:exception, filled_exception, stack, quoted_ast}
  end

  defp purge_removed_modules(old_modules, new_modules) do
    new_modules = MapSet.new(new_modules, fn {module, _bytecode} -> module end)
    old_modules = MapSet.new(old_modules)

    old_modules
    |> MapSet.difference(new_modules)
    |> Enum.each(fn to_remove ->
      :code.purge(to_remove)
      :code.delete(to_remove)
    end)
  end

  defp replace_source(result, source) do
    Map.put(result, :source, source)
  end

  @doc false
  def wrap_top_level_forms({:__block__, meta, nodes}) do
    {chunks, _vars} =
      nodes
      |> Enum.chunk_by(&should_wrap?/1)
      |> Enum.with_index()
      |> Enum.flat_map_reduce([], fn {[node | _] = nodes, i}, vars ->
        if should_wrap?(node) do
          {wrapped, vars} = wrap_nodes(nodes, vars, i)
          {[wrapped], vars}
        else
          {nodes, vars}
        end
      end)

    {:__block__, meta, chunks}
  end

  def wrap_top_level_forms(ast) do
    wrap_top_level_forms({:__block__, [], [ast]})
  end

  defp wrap_nodes(nodes, vars, i) do
    module_name = :"expert_wrapper_#{i}"
    {nodes, new_vars} = suppress_and_extract_vars(nodes)

    quoted =
      quote do
        defmodule unquote(module_name) do
          def __expert_wrapper__([unquote_splicing(vars)]) do
            (unquote_splicing(nodes))
          end
        end
      end

    {quoted, new_vars ++ vars}
  end

  @allowed_top_level [:defmodule, :alias, :import, :require, :use]
  defp should_wrap?({allowed, _, _}) when allowed in @allowed_top_level, do: false
  defp should_wrap?(_), do: true

  @doc false
  # This function replaces all unused variables with `_` in order
  # to suppress warnings while accumulating those vars. The approach
  # here is bottom-up, starting from the last expression and working
  # back to the beginning:
  #
  #   - If the expression is an assignment, collect vars from the LHS,
  #     replacing them with `_` if they haven't been referenced, then
  #     collect references from the RHS.
  #   - If the expression isn't an assignment, just collect references.
  #   - Note that pinned vars on the LHS of an assignment are references.
  #
  def suppress_and_extract_vars(quoted)

  def suppress_and_extract_vars(list) when is_list(list) do
    list
    |> Enum.reverse()
    |> do_suppress_and_extract_vars()
  end

  def suppress_and_extract_vars({:__block__, meta, nodes}) do
    {nodes, vars} = suppress_and_extract_vars(nodes)
    {{:__block__, meta, nodes}, vars}
  end

  def suppress_and_extract_vars(expr) do
    {[expr], vars} = suppress_and_extract_vars([expr])
    {expr, vars}
  end

  defp do_suppress_and_extract_vars(list, acc \\ [], references \\ [], vars \\ [])

  defp do_suppress_and_extract_vars([expr | rest], acc, references, vars) do
    {expr, new_vars} = suppress_and_extract_vars_from_expr(expr, references)
    new_references = extract_references_from_expr(expr)

    do_suppress_and_extract_vars(
      rest,
      [expr | acc],
      new_references ++ references,
      new_vars ++ vars
    )
  end

  defp do_suppress_and_extract_vars([], acc, _references, vars) do
    {acc, vars}
  end

  defp suppress_and_extract_vars_from_expr({:=, meta, [left, right]}, references) do
    {left, left_vars} =
      Ast.prewalk_vars(left, [], fn
        {:^, _, _} = pinned, acc ->
          {pinned, acc}

        {name, meta, context} = var, acc ->
          if Ast.has_var?(references, name, context) do
            {var, [{name, [], context} | acc]}
          else
            {{:_, meta, nil}, [var | acc]}
          end
      end)

    {right, right_vars} = suppress_and_extract_vars_from_expr(right, references)

    {{:=, meta, [left, right]}, left_vars ++ right_vars}
  end

  defp suppress_and_extract_vars_from_expr(other, _references) do
    {other, []}
  end

  defp extract_references_from_expr({:=, _, [left, right]}) do
    {_, left_references} =
      Ast.prewalk_vars(left, [], fn
        {:^, _, [referenced_var]}, acc ->
          {:ok, [referenced_var | acc]}

        node, acc ->
          {node, acc}
      end)

    right_references = extract_references_from_expr(right)

    left_references ++ right_references
  end

  defp extract_references_from_expr(expr) do
    {_, references} =
      Ast.prewalk_vars(expr, [], fn
        {:^, _, _}, acc ->
          {:ok, acc}

        var, acc ->
          {:ok, [var | acc]}
      end)

    references
  end
end
