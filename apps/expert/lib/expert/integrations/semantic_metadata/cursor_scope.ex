defmodule Expert.Integrations.SemanticMetadata.CursorScope do
  @moduledoc false

  @type t :: %__MODULE__{
          argument: Macro.t() | nil,
          arguments: [Macro.t()],
          call: Macro.t() | nil,
          data: keyword(),
          document: map() | nil,
          entries: [map()],
          id: term(),
          position: {:argument, non_neg_integer()} | {:block, atom()} | :document | :sigil | nil,
          sigil: map() | nil,
          target: mfa() | nil
        }

  defstruct [
    :argument,
    :call,
    :document,
    :id,
    :position,
    :sigil,
    :target,
    arguments: [],
    data: [],
    entries: []
  ]
end
