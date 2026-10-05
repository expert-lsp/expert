defmodule Forge.Ast.Analysis.Use do
  alias Forge.Ast
  alias Forge.Document

  defstruct [:module, :range, :opts, imported_mfas: nil]

  def new(%Document{} = document, ast, module, opts, imported_mfas \\ nil) do
    range = Ast.Range.get(ast, document)
    %__MODULE__{range: range, module: module, opts: opts, imported_mfas: imported_mfas}
  end
end
