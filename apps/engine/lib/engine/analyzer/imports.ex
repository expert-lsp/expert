defmodule Engine.Analyzer.Imports do
  @moduledoc false

  alias Engine.Module.Loader
  alias Forge.Ast.Analysis.Aliases
  alias Forge.Ast.Analysis.Imports

  def at(analysis, position),
    do: Imports.at(analysis, position, &Aliases.resolve_at/3, &module_exports/1)

  def module_for(analysis, position, function, arity),
    do:
      Imports.module_for(
        analysis,
        position,
        function,
        arity,
        &Aliases.resolve_at/3,
        &module_exports/1
      )

  def imports(scope, position \\ :end),
    do: Imports.imports(scope, position, &Aliases.resolve_at/3, &module_exports/1)

  defp module_exports(module) do
    if Loader.ensure_loaded?(module) and function_exported?(module, :__info__, 1) do
      {:ok, %{functions: module.__info__(:functions), macros: module.__info__(:macros)}}
    else
      :error
    end
  end
end
