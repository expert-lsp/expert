defmodule Engine.CodeMod.Diff do
  @moduledoc false

  alias Forge.Document

  @doc """
  Delegates to `Forge.Document.Diff.diff/2`.
  """
  @spec diff(Document.t(), String.t()) :: [Forge.Document.Edit.t()]
  defdelegate diff(document, dest), to: Forge.Document.Diff
end
