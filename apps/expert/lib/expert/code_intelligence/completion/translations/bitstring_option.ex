defmodule Expert.CodeIntelligence.Completion.Translations.BitstringOption do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations
  alias Forge.Ast.Env
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.BitstringOption do
    def translate(option, builder, %Env{} = env) do
      Translations.BitstringOption.translate(option, builder, env)
    end
  end

  def translate(%Candidate.BitstringOption{} = option, builder, %Env{} = env) do
    env
    |> builder.plain_text(option.name,
      filter_text: option.name,
      kind: CompletionItemKind.unit(),
      label: option.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end
end
