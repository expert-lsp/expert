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

      case {generic.snippet, range(generic, env)} do
        {snippet, nil} when is_binary(snippet) ->
          builder.snippet(env, insertion_text(snippet, env), options)

        {snippet, range} when is_binary(snippet) ->
          builder.text_edit_snippet(env, snippet, range, options)

        {_snippet, nil} ->
          builder.plain_text(
            env,
            insertion_text(generic.insert_text || generic.label, env),
            options
          )

        {_snippet, range} ->
          builder.text_edit(env, generic.insert_text || generic.label, range, options)
      end
    end

    defp range(%Candidate.Generic{range: {line, start_character, end_character}}, %Env{} = env)
         when line == env.position.line and start_character <= env.position.character and
                env.position.character <= end_character,
         do: {start_character, end_character}

    defp range(_generic, _env), do: nil

    defp insertion_text(text, %Env{} = env) do
      case Code.Fragment.cursor_context(env.prefix) do
        {:unquoted_atom, _atom} -> ":" <> String.trim_leading(text, ":")
        _context -> text
      end
    end

    defp kind(kind), do: Map.get(@kinds, kind, CompletionItemKind.text())
  end
end
