defmodule Expert.Search.Indexer.Analysis.Imports do
  @moduledoc false

  alias Forge.Ast.Analysis.Aliases
  alias Forge.Ast.Analysis.Imports

  def at(analysis, position, module_exports \\ &module_exports/1),
    do: Imports.at(analysis, position, &Aliases.resolve_at/3, module_exports)

  def module_for(analysis, position, function, arity, module_exports \\ &module_exports/1),
    do:
      Imports.module_for(
        analysis,
        position,
        function,
        arity,
        &Aliases.resolve_at/3,
        module_exports
      )

  def imports(scope, position \\ :end, module_exports \\ &module_exports/1),
    do: Imports.imports(scope, position, &Aliases.resolve_at/3, module_exports)

  defp module_exports(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__info__, 1) do
      {:ok, %{functions: module.__info__(:functions), macros: module.__info__(:macros)}}
    else
      _ -> :error
    end
  end
end
