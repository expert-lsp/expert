defmodule Expert.CodeIntelligence.Completion.Translations.Snippet do
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.Snippet do
    def translate(%{priority: :contextual} = snippet, builder, %Env{} = env) do
      builder.snippet(env, snippet.snippet,
        detail: snippet.detail,
        documentation: snippet.documentation,
        filter_text: snippet.filter_text,
        kind: kind(snippet.kind),
        label: snippet.label
      )
    end

    def translate(_snippet, _builder, _env), do: :skip

    defp kind(:function), do: CompletionItemKind.function()
    defp kind(:field), do: CompletionItemKind.field()
    defp kind(:enum_member), do: CompletionItemKind.enum_member()
    defp kind(_kind), do: CompletionItemKind.snippet()
  end
end
