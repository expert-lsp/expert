defmodule Expert.Integrations.SemanticMetadata.Hover do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.Providers
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document.Position
  alias Forge.Document.Range

  @impl Expert.Integrations
  def hover(%Env{} = env) do
    with false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         {:ok, %{begin: begin_pos, context: context, end: end_pos}} <-
           Ast.surround_context(env.analysis, env.position),
         name when is_binary(name) <- hover_name(context),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, scope} <- Common.scope_at(env, cursor_path) do
      range = to_range(env, begin_pos, end_pos)

      provider_hovers =
        scope
        |> Providers.hover(cursor_path, env, name, range)
        |> Enum.map(&{&1, range})

      provider_hovers ++ entry_hovers(scope, name, env, range)
    else
      _error -> []
    end
  end

  defp entry_hovers(scope, name, env, range) do
    with %{value: candidate} <-
           Enum.find(scope.candidates, &(Common.candidate_name(&1.value) == name)),
         documentation when documentation != "" <- Common.documentation(candidate, env.project) do
      [{documentation, range}]
    else
      _error -> []
    end
  end

  defp to_range(env, {begin_line, begin_column}, {end_line, end_column}) do
    Range.new(
      Position.new(env.document, begin_line, begin_column),
      Position.new(env.document, end_line, end_column)
    )
  end

  defp hover_name({context, chars})
       when context in [:keyword, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp hover_name({:dot, _base, chars}), do: to_string(chars)
  defp hover_name(_context), do: nil
end
