defmodule Expert.Integrations.SemanticMetadata.SignatureHelp do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Forge.Ast
  alias Forge.Ast.Env

  @impl Expert.Integrations
  def signature_help(%Env{} = env) do
    with [_ | _] = documents <- Common.records(env.project),
         false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         env = Common.with_cursor_env(env),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, scope} <- Common.scope_at(env, cursor_path, documents),
         [_ | _] = signatures <- Handlers.signature_help(scope, cursor_path, env) do
      signatures
    else
      _error -> :ignore
    end
  end
end
