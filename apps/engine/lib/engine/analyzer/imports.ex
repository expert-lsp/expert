defmodule Engine.Analyzer.Imports do
  alias Engine.Analyzer.Aliases
  alias Engine.Module.Loader
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.ProcessCache

  @spec at(Analysis.t(), Position.t()) :: [Scope.import_mfa()]
  def at(%Analysis{} = analysis, %Position{} = position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        imports(scope, position)

      _ ->
        []
    end
  end

  @doc """
  Returns the source module for an imported function by walking import declarations in scope.
  """
  @spec module_for(Analysis.t(), Position.t(), atom(), non_neg_integer()) ::
          {:ok, module()} | :error
  def module_for(%Analysis{} = analysis, %Position{} = position, function_name, arity) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        case latest_use_with_imports(scope, position) do
          nil ->
            explicit_module_for(scope, position, nil, function_name, arity)

          use ->
            module_for_after_use(scope, position, use, function_name, arity)
        end

      _ ->
        :error
    end
  end

  defp latest_use_with_imports(scope, position) do
    [scope.latest_expanded_use | scope.uses]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(fn use ->
      is_list(use.imported_mfas) and Position.compare(use.range.end, position) in [:lt, :eq]
    end)
    |> Enum.max_by(&{&1.range.end.line, &1.range.end.character}, fn -> nil end)
  end

  defp module_for_after_use(scope, position, use, function_name, arity) do
    case used_module_for(imports_after_use(scope, position, use), function_name, arity) do
      {:ok, _module} = found -> found
      :error -> explicit_module_for(scope, position, use.range.end, function_name, arity)
    end
  end

  defp explicit_module_for(scope, position, after_position, function_name, arity) do
    imports =
      scope.imports
      |> Enum.filter(&import_in_range?(&1, after_position, position))
      |> Enum.sort_by(&{&1.range.start.line, &1.range.start.character}, :desc)

    imports = if after_position, do: imports, else: imports ++ kernel_imports(scope)

    imports
    |> Enum.find_value(:error, fn %Import{} = import ->
      module = Aliases.resolve_at(scope, import.module, import.range.start.line)

      if import_allows?(module, import.selector, function_name, arity) do
        {:ok, module}
      else
        false
      end
    end)
  end

  defp import_in_range?(import, after_position, position) do
    before_call? = Position.compare(import.range.start, position) in [:lt, :eq]

    after_use? =
      is_nil(after_position) or Position.compare(import.range.start, after_position) == :gt

    before_call? and after_use?
  end

  defp imports_after_use(scope, position, use) do
    imports = Enum.group_by(use.imported_mfas, &elem(&1, 0))

    scope.imports
    |> Enum.filter(&import_in_range?(&1, use.range.end, position))
    |> Enum.sort_by(&{&1.range.start.line, &1.range.start.character})
    |> Enum.reduce(imports, &apply_to_scope(&1, scope, &2))
    |> Map.values()
    |> List.flatten()
  end

  defp used_module_for(imported_mfas, function_name, arity) do
    Enum.find_value(imported_mfas, :error, fn
      {module, ^function_name, ^arity} -> {:ok, module}
      _ -> false
    end)
  end

  defp import_allows?(module, :all, fun, arity) do
    not Loader.ensure_loaded?(module) or
      {fun, arity} in function_and_arities_for_module(module, :functions) or
      {fun, arity} in function_and_arities_for_module(module, :macros)
  end

  defp import_allows?(module, [only: :functions], fun, arity) do
    not Loader.ensure_loaded?(module) or
      {fun, arity} in function_and_arities_for_module(module, :functions)
  end

  defp import_allows?(module, [only: :macros], fun, arity) do
    not Loader.ensure_loaded?(module) or
      {fun, arity} in function_and_arities_for_module(module, :macros)
  end

  defp import_allows?(module, [only: :sigils], fun, arity) do
    not Loader.ensure_loaded?(module) or
      {fun, arity} in function_and_arities_for_module(module, :sigils)
  end

  defp import_allows?(_module, [only: fns], fun, arity) when is_list(fns),
    do: {fun, arity} in fns

  defp import_allows?(module, [except: fns], fun, arity) when is_list(fns) do
    {fun, arity} not in fns and
      (not Loader.ensure_loaded?(module) or
         {fun, arity} in function_and_arities_for_module(module, :functions) or
         {fun, arity} in function_and_arities_for_module(module, :macros))
  end

  defp import_allows?(_module, _selector, _fun, _arity), do: false

  @spec imports(Scope.t(), Scope.scope_position()) :: [Scope.import_mfa()]
  def imports(%Scope{} = scope, position \\ :end) do
    scope
    |> import_map(position)
    |> Map.values()
    |> List.flatten()
  end

  defp import_map(%Scope{} = scope, position) do
    end_line = Scope.end_line(scope, position)

    (kernel_imports(scope) ++ scope.imports)
    # sorting by line ensures that imports on later lines
    # override imports on earlier lines
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(&(&1.range.start.line <= end_line))
    |> Enum.reduce(%{}, fn %Import{} = import, current_imports ->
      apply_to_scope(import, scope, current_imports)
    end)
  end

  defp apply_to_scope(%Import{} = import, current_scope, %{} = current_imports) do
    import_module = Aliases.resolve_at(current_scope, import.module, import.range.start.line)

    functions = mfas_for(import_module, :functions)
    macros = mfas_for(import_module, :macros)

    case import.selector do
      :all ->
        Map.put(current_imports, import_module, functions ++ macros)

      [only: :functions] ->
        Map.put(current_imports, import_module, functions)

      [only: :macros] ->
        Map.put(current_imports, import_module, macros)

      [only: :sigils] ->
        sigils = mfas_for(import_module, :sigils)
        Map.put(current_imports, import_module, sigils)

      [only: functions_to_import] ->
        functions_to_import = function_and_arity_to_mfa(import_module, functions_to_import)
        Map.put(current_imports, import_module, functions_to_import)

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

  defp mfas_for(current_module, type) do
    if Loader.ensure_loaded?(current_module) do
      fa_list = function_and_arities_for_module(current_module, type)

      function_and_arity_to_mfa(current_module, fa_list)
    else
      []
    end
  end

  defp function_and_arities_for_module(module, :sigils) do
    ProcessCache.trans({module, :info, :sigils}, fn ->
      for {name, arity} <- module.__info__(:functions),
          string_name = Atom.to_string(name),
          sigil?(string_name, arity) do
        {name, arity}
      end
    end)
  end

  defp function_and_arities_for_module(module, type) do
    ProcessCache.trans({module, :info, type}, fn ->
      type
      |> module.__info__()
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
end
