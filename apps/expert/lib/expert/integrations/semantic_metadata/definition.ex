defmodule Expert.Integrations.SemanticMetadata.Definition do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Forge.Ast
  alias Forge.Ast.Env

  @impl Expert.Integrations
  def definition(%Env{} = env) do
    with [_ | _] = documents <- Common.records(env.project),
         false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         env = Common.with_cursor_env(env),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, scope} <- Common.scope_at(env, cursor_path, documents) do
      {identifier, range} = Common.identifier_at(env)
      Handlers.definition(scope, cursor_path, env, identifier, range)
    else
      _error -> []
    end
  end
end
