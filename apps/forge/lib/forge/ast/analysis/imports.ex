defmodule Forge.Ast.Analysis.Imports do
  @moduledoc false

  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position
  alias Forge.Document.Range

  def at(%Analysis{} = analysis, %Position{} = position, resolve_alias, module_exports) do
    scope_imports = scope_imports(analysis, position, resolve_alias, module_exports)

    case Analysis.cursor_env_at(analysis, position) do
      %{imports: imports} -> Enum.uniq(imports ++ scope_imports)
      nil -> scope_imports
    end
  end

  def module_for(
        %Analysis{} = analysis,
        %Position{} = position,
        function_name,
        arity,
        resolve_alias,
        module_exports
      ) do
    case Analysis.cursor_env_at(analysis, position) do
      %{imports: imports} ->
        modules = for {module, ^function_name, ^arity} <- imports, do: module

        case Enum.reject(modules, &(&1 == Kernel)) do
          [module | _] ->
            {:ok, module}

          [] ->
            case scope_module_for(
                   analysis,
                   position,
                   function_name,
                   arity,
                   resolve_alias,
                   module_exports
                 ) do
              :error when modules != [] -> {:ok, Kernel}
              result -> result
            end
        end

      nil ->
        scope_module_for(
          analysis,
          position,
          function_name,
          arity,
          resolve_alias,
          module_exports
        )
    end
  end

  def imports(%Scope{} = scope, position, resolve_alias, module_exports) do
    scope
    |> import_map(position, resolve_alias, module_exports)
    |> Map.values()
    |> List.flatten()
  end

  defp scope_imports(analysis, position, resolve_alias, module_exports) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        case latest_use_with_imports(scope, position) do
          nil -> imports(scope, position, resolve_alias, module_exports)
          use -> imports_after_use(scope, position, use, resolve_alias, module_exports)
        end

      _ ->
        []
    end
  end

  defp scope_module_for(
         analysis,
         position,
         function_name,
         arity,
         resolve_alias,
         module_exports
       ) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        case latest_use_with_imports(scope, position) do
          nil ->
            explicit_module_for(
              scope,
              position,
              nil,
              function_name,
              arity,
              resolve_alias,
              module_exports
            )

          use ->
            module_for_after_use(
              scope,
              position,
              use,
              function_name,
              arity,
              resolve_alias,
              module_exports
            )
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
    |> Enum.max_by(&position_key(&1.range.end), fn -> nil end)
  end

  defp module_for_after_use(
         scope,
         position,
         use,
         function_name,
         arity,
         resolve_alias,
         module_exports
       ) do
    imports = imports_after_use(scope, position, use, resolve_alias, module_exports)

    case used_module_for(imports, function_name, arity) do
      {:ok, _module} = found ->
        found

      :error ->
        explicit_module_for(
          scope,
          position,
          use.range.end,
          function_name,
          arity,
          resolve_alias,
          module_exports
        )
    end
  end

  defp explicit_module_for(
         scope,
         position,
         after_position,
         function_name,
         arity,
         resolve_alias,
         module_exports
       ) do
    selected =
      scope.imports
      |> Enum.filter(&import_in_range?(&1, after_position, position))
      |> Enum.sort_by(&position_key(&1.range.start), :desc)

    selected = if after_position, do: selected, else: selected ++ kernel_imports(scope)

    Enum.find_value(selected, :error, fn %Import{} = import ->
      module = resolve_alias.(scope, import.module, import.range.start)

      if import_allows?(module, import.selector, function_name, arity, module_exports) do
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

  defp imports_after_use(scope, position, use, resolve_alias, module_exports) do
    scope.imports
    |> Enum.filter(&import_in_range?(&1, use.range.end, position))
    |> Enum.sort_by(&position_key(&1.range.start))
    |> Enum.reduce(
      Enum.group_by(use.imported_mfas, &elem(&1, 0)),
      &apply_to_scope(&1, scope, &2, resolve_alias, module_exports)
    )
    |> Map.values()
    |> List.flatten()
  end

  defp used_module_for(imported_mfas, function_name, arity) do
    Enum.find_value(imported_mfas, :error, fn
      {module, ^function_name, ^arity} -> {:ok, module}
      _ -> false
    end)
  end

  defp import_allows?(module, :all, function, arity, module_exports) do
    exports = module_exports.(module)

    unavailable?(exports) or exported?(exports, :functions, function, arity) or
      exported?(exports, :macros, function, arity)
  end

  defp import_allows?(module, [only: type], function, arity, module_exports)
       when type in [:functions, :macros, :sigils] do
    exports = module_exports.(module)
    unavailable?(exports) or exported?(exports, type, function, arity)
  end

  defp import_allows?(_module, [only: functions], function, arity, _module_exports)
       when is_list(functions),
       do: {function, arity} in functions

  defp import_allows?(module, [except: functions], function, arity, module_exports)
       when is_list(functions) do
    exports = module_exports.(module)

    {function, arity} not in functions and
      (unavailable?(exports) or exported?(exports, :functions, function, arity) or
         exported?(exports, :macros, function, arity))
  end

  defp import_allows?(_module, _selector, _function, _arity, _module_exports), do: false

  defp import_map(%Scope{} = scope, position, resolve_alias, module_exports) do
    (kernel_imports(scope) ++ scope.imports)
    |> Enum.sort_by(&position_key(&1.range.start))
    |> Enum.take_while(&before?(&1.range.start, position))
    |> Enum.reduce(%{}, &apply_to_scope(&1, scope, &2, resolve_alias, module_exports))
  end

  defp apply_to_scope(
         %Import{} = import,
         scope,
         current_imports,
         resolve_alias,
         module_exports
       ) do
    module = resolve_alias.(scope, import.module, import.range.start)
    exports = module_exports.(module)
    functions = mfas_for(module, :functions, exports)
    macros = mfas_for(module, :macros, exports)

    case import.selector do
      :all ->
        Map.put(current_imports, module, functions ++ macros)

      [only: :functions] ->
        Map.put(current_imports, module, functions)

      [only: :macros] ->
        Map.put(current_imports, module, macros)

      [only: :sigils] ->
        Map.put(current_imports, module, mfas_for(module, :sigils, exports))

      [only: selected] ->
        Map.put(current_imports, module, to_mfas(selected, module))

      [except: excluded] ->
        excluded = to_mfas(excluded, module)

        if Map.get(current_imports, module, []) == [] do
          Map.put(current_imports, module, (functions ++ macros) -- excluded)
        else
          Map.update!(current_imports, module, &(&1 -- excluded))
        end
    end
  end

  defp mfas_for(module, type, exports) do
    case exports do
      {:ok, exports} -> type |> function_and_arities(exports) |> to_mfas(module)
      :error -> []
    end
  end

  defp function_and_arities(:sigils, exports) do
    for {name, arity} <- exports.functions,
        sigil?(Atom.to_string(name), arity),
        do: {name, arity}
  end

  defp function_and_arities(type, exports) do
    exports
    |> Map.fetch!(type)
    |> Enum.reject(fn {name, arity} ->
      string_name = Atom.to_string(name)
      String.starts_with?(string_name, "_") or sigil?(string_name, arity)
    end)
  end

  defp exported?(exports, type, function, arity) do
    case exports do
      {:ok, exports} -> {function, arity} in function_and_arities(type, exports)
      :error -> false
    end
  end

  defp unavailable?(:error), do: true
  defp unavailable?({:ok, _exports}), do: false

  defp to_mfas(functions, module) when is_list(functions),
    do: Enum.map(functions, fn {function, arity} -> {module, function, arity} end)

  defp sigil?(name, arity), do: String.starts_with?(name, "sigil_") and arity in [1, 2]

  defp before?(_position, :end), do: true
  defp before?(%Position{line: line}, end_line) when is_integer(end_line), do: line <= end_line
  defp before?(position, %Position{} = stop), do: Position.compare(position, stop) in [:lt, :eq]

  defp position_key(%Position{line: line, character: character}), do: {line, character}

  defp kernel_imports(%Scope{range: %{start: start}}) do
    range = Range.new(start, start)
    [Import.implicit(range, [:Kernel]), Import.implicit(range, [:Kernel, :SpecialForms])]
  end
end
