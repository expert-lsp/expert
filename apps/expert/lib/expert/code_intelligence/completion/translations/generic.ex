defmodule Expert.CodeIntelligence.Completion.Translations.Generic do
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.Generic do
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
        {:unquoted_atom, _atom} -> text |> String.trim_leading(":") |> then(&(":" <> &1))
        _context -> text
      end
    end

    defp kind(:class), do: CompletionItemKind.class()
    defp kind(:color), do: CompletionItemKind.color()
    defp kind(:constant), do: CompletionItemKind.constant()
    defp kind(:constructor), do: CompletionItemKind.constructor()
    defp kind(:enum), do: CompletionItemKind.enum()
    defp kind(:enum_member), do: CompletionItemKind.enum_member()
    defp kind(:event), do: CompletionItemKind.event()
    defp kind(:field), do: CompletionItemKind.field()
    defp kind(:file), do: CompletionItemKind.file()
    defp kind(:folder), do: CompletionItemKind.folder()
    defp kind(:function), do: CompletionItemKind.function()
    defp kind(:interface), do: CompletionItemKind.interface()
    defp kind(:keyword), do: CompletionItemKind.keyword()
    defp kind(:method), do: CompletionItemKind.method()
    defp kind(:module), do: CompletionItemKind.module()
    defp kind(:operator), do: CompletionItemKind.operator()
    defp kind(:property), do: CompletionItemKind.property()
    defp kind(:reference), do: CompletionItemKind.reference()
    defp kind(:snippet), do: CompletionItemKind.snippet()
    defp kind(:struct), do: CompletionItemKind.struct()
    defp kind(:text), do: CompletionItemKind.text()
    defp kind(:type_parameter), do: CompletionItemKind.type_parameter()
    defp kind(:unit), do: CompletionItemKind.unit()
    defp kind(:value), do: CompletionItemKind.value()
    defp kind(:variable), do: CompletionItemKind.variable()
    defp kind(_kind), do: CompletionItemKind.text()
  end
end
