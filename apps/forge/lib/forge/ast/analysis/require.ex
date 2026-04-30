defmodule Forge.Ast.Analysis.Require do
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Range

  defstruct [:module, :as, :range]

  @type t :: %__MODULE__{
          module: [atom],
          as: atom() | [atom],
          range: Range.t() | nil
        }

  def new(%Document{} = document, ast, module, as \\ nil) when is_list(module) do
    range = Ast.Range.get(ast, document)
    %__MODULE__{module: module, as: as || module, range: range}
  end

  def to_module(%__MODULE__{module: module}), do: Module.concat(module)
end
