defmodule Expert.CodeIntelligence.Completion.Translations.Generic do
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.Generic do
    @kinds Map.new(Candidate.Generic.kinds(), &{&1, apply(CompletionItemKind, &1, [])})

    def translate(generic, builder, %Env{} = env) do
      options = [
        detail: generic.detail,
        documentation: generic.documentation,
        filter_text: generic.filter_text,
        kind: kind(generic.kind),
        label: generic.label
      ]

      case generic.snippet do
        snippet when is_binary(snippet) ->
          builder.snippet(env, insertion_text(snippet, env), options)

        _snippet ->
          builder.plain_text(
            env,
            insertion_text(generic.insert_text || generic.label, env),
            options
          )
      end
    end

    defp insertion_text(text, %Env{} = env) do
      case Code.Fragment.cursor_context(env.prefix) do
        {:unquoted_atom, _atom} -> ":" <> String.trim_leading(text, ":")
        _context -> text
      end
    end

    defp kind(kind), do: Map.get(@kinds, kind, CompletionItemKind.text())
  end
end
