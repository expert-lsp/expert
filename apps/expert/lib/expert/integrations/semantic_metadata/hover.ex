defmodule Expert.Integrations.SemanticMetadata.Hover do
  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Common
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document.Position
  alias Forge.Document.Range

  @impl Expert.Integrations
  def hover(%Env{} = env) do
    with [_ | _] = documents <- Common.records(env.project),
         false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         {:ok,
          %{begin: {begin_line, begin_column}, context: context, end: {end_line, end_column}}} <-
           Ast.surround_context(env.analysis, env.position),
         name when is_binary(name) <- hover_name(context),
         env = Common.with_cursor_env(env),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, scope} <- Common.scope_at(env, cursor_path, documents) do
      range =
        Range.new(
          Position.new(env.document, begin_line, begin_column),
          Position.new(env.document, end_line, end_column)
        )

      entry_hovers(scope, name, env, range)
    else
      _error -> []
    end
  end

  defp entry_hovers(scope, name, env, range) do
    with %{} = entry <- Enum.find(scope.entries, &(Common.entry_name(&1) == name)),
         documentation when documentation != "" <- Common.documentation(entry, env.project) do
      [{documentation, range}]
    else
      _error -> []
    end
  end

  defp hover_name({context, chars})
       when context in [:keyword, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp hover_name({:dot, _base, chars}), do: to_string(chars)
  defp hover_name(_context), do: nil
end
