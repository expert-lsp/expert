defmodule Expert.Integrations.SemanticMetadata.Completion do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Forge.Ast
  alias Forge.Ast.Env

  @impl Expert.Integrations
  def complete(%Env{} = env) do
    with [_ | _] = documents <- Common.records(env.project),
         false <- Env.in_context?(env, :comment),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, scope} <- Common.scope_at(env, cursor_path, documents) do
      static_result(scope, env)
    else
      _ -> :ignore
    end
  end

  defp static_result(scope, %Env{} = env) do
    if Env.in_context?(env, :string) or
         match?({:dot, _, _}, Code.Fragment.cursor_context(env.prefix)) do
      :ignore
    else
      existing_keywords = Common.existing_keywords(scope)
      hint = env |> Common.hint() |> String.downcase()

      entries =
        for entry <- scope.entries,
            not existing_keyword?(entry, existing_keywords),
            entry |> Common.entry_name() |> String.downcase() |> String.starts_with?(hint),
            do: entry

      result(for item <- Common.items(entries, env.project), do: {item, []})
    end
  end

  defp existing_keyword?(%{kind: :keyword, name: name}, existing),
    do: Atom.to_string(name) in existing

  defp existing_keyword?(_entry, _existing), do: false

  defp result([]), do: :ignore
  defp result(candidates), do: {:augment, candidates, true, []}
end
