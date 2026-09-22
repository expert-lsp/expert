defmodule Expert.Search.Indexer.Analysis.Imports do
  alias Expert.Search.Indexer.Analysis.Aliases
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.ProcessCache

  @spec at(Analysis.t(), Position.t()) :: [Scope.import_mfa()]
  def at(%Analysis{} = analysis, %Position{} = position, module_exports \\ &module_exports/1) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        imports(scope, position, module_exports)

      _ ->
        []
    end
  end

  @doc """
  Returns the source module for an imported function by walking import declarations in scope.
  """
  @spec module_for(Analysis.t(), Position.t(), atom(), non_neg_integer()) ::
          {:ok, module()} | :error
  def module_for(
        %Analysis{} = analysis,
        %Position{} = position,
        function_name,
        arity,
        module_exports \\ &module_exports/1
      ) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        end_line = Scope.end_line(scope, position)

        scope.imports
        |> Enum.sort_by(& &1.range.start.line)
        |> Enum.take_while(&(&1.range.start.line <= end_line))
        |> Enum.reverse(kernel_imports(scope))
        |> Enum.find_value(:error, fn %Import{} = import ->
          module = Aliases.resolve_at(scope, import.module, import.range.start.line)

          if import_allows?(module, import.selector, function_name, arity, module_exports) do
            {:ok, module}
          else
            false
          end
        end)

      _ ->
        :error
    end
  end

  defp import_allows?(module, :all, fun, arity, module_exports) do
    not loaded?(module, module_exports) or
      {fun, arity} in fetch_function_and_arities(module, :functions, module_exports) or
      {fun, arity} in fetch_function_and_arities(module, :macros, module_exports)
  end

  defp import_allows?(module, [only: :functions], fun, arity, module_exports) do
    not loaded?(module, module_exports) or
      {fun, arity} in fetch_function_and_arities(module, :functions, module_exports)
  end

  defp import_allows?(module, [only: :macros], fun, arity, module_exports) do
    not loaded?(module, module_exports) or
      {fun, arity} in fetch_function_and_arities(module, :macros, module_exports)
  end

  defp import_allows?(module, [only: :sigils], fun, arity, module_exports) do
    not loaded?(module, module_exports) or
      {fun, arity} in fetch_function_and_arities(module, :sigils, module_exports)
  end

  defp import_allows?(_module, [only: fns], fun, arity, _module_exports) when is_list(fns),
    do: {fun, arity} in fns

  defp import_allows?(module, [except: fns], fun, arity, module_exports) when is_list(fns) do
    {fun, arity} not in fns and
      (not loaded?(module, module_exports) or
         {fun, arity} in fetch_function_and_arities(module, :functions, module_exports) or
         {fun, arity} in fetch_function_and_arities(module, :macros, module_exports))
  end

  defp import_allows?(_module, _selector, _fun, _arity, _module_exports), do: false

  @spec imports(Scope.t(), Scope.scope_position()) :: [Scope.import_mfa()]
  def imports(%Scope{} = scope, position \\ :end, module_exports \\ &module_exports/1) do
    scope
    |> import_map(position, module_exports)
    |> Map.values()
    |> List.flatten()
  end

  defp import_map(%Scope{} = scope, position, module_exports) do
    end_line = Scope.end_line(scope, position)

    (kernel_imports(scope) ++ scope.imports)
    # sorting by line ensures that imports on later lines
    # override imports on earlier lines
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(&(&1.range.start.line <= end_line))
    |> Enum.reduce(%{}, fn %Import{} = import, current_imports ->
      apply_to_scope(import, scope, current_imports, module_exports)
    end)
  end

  defp apply_to_scope(
         %Import{} = import,
         current_scope,
         %{} = current_imports,
         module_exports
       ) do
    import_module = Aliases.resolve_at(current_scope, import.module, import.range.start.line)

    functions = mfas_for(import_module, :functions, module_exports)
    macros = mfas_for(import_module, :macros, module_exports)

    case import.selector do
      :all ->
        Map.put(current_imports, import_module, functions ++ macros)

      [only: :functions] ->
        Map.put(current_imports, import_module, functions)

      [only: :macros] ->
        Map.put(current_imports, import_module, macros)

      [only: :sigils] ->
        Map.put(current_imports, import_module, mfas_for(import_module, :sigils, module_exports))

      [only: functions_to_import] ->
        Map.put(
          current_imports,
          import_module,
          function_and_arity_to_mfa(import_module, functions_to_import)
        )

      [except: functions_to_except] ->
        # This one is a little tricky. Imports using except have two cases.
        # In the first case, if the module hasn't been previously imported, we
        # collect all the functions in the current module and remove the ones in the
        # except clause.
        # If the module has been previously imported, we just remove the functions from
        # the except clause from those that have been previously imported.
        # See: https://hexdocs.pm/elixir/1.13.0/Kernel.SpecialForms.html#import/2-selector

        functions_to_except = function_and_arity_to_mfa(import_module, functions_to_except)

        if already_imported?(current_imports, import_module) do
          Map.update!(current_imports, import_module, fn old_imports ->
            old_imports -- functions_to_except
          end)
        else
          to_import = (functions ++ macros) -- functions_to_except
          Map.put(current_imports, import_module, to_import)
        end
    end
  end

  defp already_imported?(%{} = current_imports, imported_module) do
    case current_imports do
      %{^imported_module => [_ | _]} -> true
      _ -> false
    end
  end

  defp function_and_arity_to_mfa(current_module, fa_list) when is_list(fa_list) do
    Enum.map(fa_list, fn {function, arity} -> {current_module, function, arity} end)
  end

  defp mfas_for(current_module, type, module_exports) do
    case module_exports.(current_module) do
      {:ok, exports} ->
        fa_list = function_and_arities_for_module(current_module, type, exports)
        function_and_arity_to_mfa(current_module, fa_list)

      :error ->
        []
    end
  end

  defp fetch_function_and_arities(module, type, module_exports) do
    case module_exports.(module) do
      {:ok, exports} -> function_and_arities_for_module(module, type, exports)
      :error -> []
    end
  end

  defp function_and_arities_for_module(module, :sigils, exports) do
    ProcessCache.trans({module, :info, :sigils}, fn ->
      for {name, arity} <- exports.functions,
          string_name = Atom.to_string(name),
          sigil?(string_name, arity) do
        {name, arity}
      end
    end)
  end

  defp function_and_arities_for_module(module, type, exports) do
    ProcessCache.trans({module, :info, type}, fn ->
      exports
      |> Map.fetch!(type)
      |> Enum.reject(fn {name, arity} ->
        string_name = Atom.to_string(name)
        String.starts_with?(string_name, "_") or sigil?(string_name, arity)
      end)
    end)
  end

  defp sigil?(string_name, arity) do
    String.starts_with?(string_name, "sigil_") and arity in [1, 2]
  end

  defp kernel_imports(%Scope{} = scope) do
    start_pos = scope.range.start
    range = Range.new(start_pos, start_pos)

    [
      Import.implicit(range, [:Kernel]),
      Import.implicit(range, [:Kernel, :SpecialForms])
    ]
  end

  defp loaded?(module, module_exports), do: match?({:ok, _}, module_exports.(module))

  defp module_exports(module) do
    ProcessCache.trans({module, :indexing_exports}, fn ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           true <- function_exported?(module, :__info__, 1) do
        {:ok, %{functions: module.__info__(:functions), macros: module.__info__(:macros)}}
      else
        _ -> :error
      end
    end)
  end
end
