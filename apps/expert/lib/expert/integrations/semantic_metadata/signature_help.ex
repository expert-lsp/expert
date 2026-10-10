defmodule Expert.Integrations.SemanticMetadata.SignatureHelp do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Providers
  alias Forge.Ast
  alias Forge.Ast.Env

  @impl Expert.Integrations
  def signature_help(%Env{} = env) do
    cursor_path = Ast.cursor_path(env.analysis, env.position)

    with false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         {:ok, scope} <- Common.scope_at(env, cursor_path),
         [_ | _] = signatures <-
           Providers.signature_help(scope, cursor_path, env, active_argument(scope)) do
      %{active_argument: active_argument(scope), signatures: signatures}
    else
      _error -> :ignore
    end
  end

  defp active_argument(%{position: {:argument, index}}), do: index
  defp active_argument(_scope), do: nil
end
