defmodule Expert.CodeIntelligence.Completion.Translations.Variable do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Forge.Ast.Env
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.Variable do
    def translate(variable, builder, %Env{} = env) do
      env
      |> builder.plain_text(variable.name,
        detail: variable.name,
        kind: CompletionItemKind.variable(),
        label: variable.name
      )
      |> builder.set_sort_scope(SortScope.variable())
    end
  end
end
