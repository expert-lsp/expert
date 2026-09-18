defmodule Engine.CodeIntelligence.SignatureHelp do
  @moduledoc """
  Signature information for the call at a document position.
  """

  alias Forge.Document
  alias Forge.Document.Position

  @spec signature(Document.t(), Position.t()) :: map() | :none
  def signature(%Document{} = document, %Position{} = position) do
    document
    |> Document.to_string()
    |> ElixirSense.signature(position.line, position.character)
  end
end
