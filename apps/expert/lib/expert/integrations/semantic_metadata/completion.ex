defmodule Expert.Integrations.SemanticMetadata.Completion do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Providers
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate

  @impl Expert.Integrations
  def complete(%Env{} = env) do
    if Env.in_context?(env, :comment) do
      :ignore
    else
      cursor_path = Ast.cursor_path(env.analysis, env.position)

      case Common.scope_at(env, cursor_path) do
        {:ok, scope} -> complete_scope(scope, cursor_path, env)
        _error -> :ignore
      end
    end
  end

  defp complete_scope(scope, cursor_path, env) do
    static_result = static_result(scope, env)
    provider_result = Providers.complete(scope, cursor_path, env)
    merge_results(static_result, provider_result)
  end

  defp static_result(scope, %Env{} = env) do
    if Env.in_context?(env, :string) or
         match?({:dot, _, _}, Code.Fragment.cursor_context(env.prefix)) do
      :ignore
    else
      existing_keywords = Common.existing_keywords(scope)
      hint = Common.hint(env)

      scope.candidates
      |> Enum.map(& &1.value)
      |> Enum.reject(&existing_keyword?(&1, existing_keywords))
      |> Enum.filter(&Common.matches?(&1, hint))
      |> Enum.map(&{Common.item(&1, env.project), []})
      |> result()
    end
  end

  defp existing_keyword?(%{kind: :keyword, name: name}, existing), do: name in existing
  defp existing_keyword?(_candidate, _existing), do: false

  defp result([]), do: :ignore
  defp result(candidates), do: {:augment, candidates, true, []}

  defp merge_results(:ignore, result), do: result
  defp merge_results(result, :ignore), do: result

  defp merge_results(
         {:augment, left_candidates, true, []},
         {right_policy, right_candidates, _right_incomplete?, right_transforms}
       ) do
    candidates = Enum.uniq_by(left_candidates ++ right_candidates, &completion_identity/1)

    {
      right_policy,
      candidates,
      true,
      Enum.uniq(right_transforms)
    }
  end

  defp completion_identity({candidate, _transforms}) do
    case candidate do
      %module{name: name, origin: origin, arity: arity}
      when module in [Candidate.Callback, Candidate.Function, Candidate.Macro, Candidate.Typespec] ->
        {module, origin, name, arity}

      _candidate ->
        {Map.get(candidate, :label), Map.get(candidate, :kind)}
    end
  end
end
