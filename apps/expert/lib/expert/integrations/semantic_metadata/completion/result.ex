defmodule Expert.Integrations.SemanticMetadata.Completion.Result do
  @moduledoc false

  alias Forge.Ast.Env

  @type mode :: :ignore | :augment | :override | :delegate
  @type t :: %__MODULE__{
          mode: mode(),
          candidates: [struct()],
          incomplete?: boolean(),
          delegate: map() | nil,
          env: Env.t() | nil
        }

  defstruct mode: :ignore, candidates: [], incomplete?: false, delegate: nil, env: nil
end
