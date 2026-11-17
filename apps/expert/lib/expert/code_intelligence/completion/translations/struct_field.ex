defmodule Expert.CodeIntelligence.Completion.Translations.StructField do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations
  alias Forge.Ast.Env
  alias Future.Code, as: Code
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.StructField do
    def translate(field, builder, %Env{} = env) do
      Translations.StructField.translate(field, builder, env)
    end
  end

  def translate(%Candidate.StructField{name: "__struct__"}, _builder, _env) do
    :skip
  end

  def translate(%Candidate.StructField{call?: false} = struct_field, builder, %Env{} = env) do
    name = struct_field.name
    value = to_string(name)

    builder_opts = [
      kind: CompletionItemKind.field(),
      label: "#{name}: #{value}",
      filter_text: "#{name}:"
    ]

    insert_text = "#{name}: ${1:#{value}}"
    range = edit_range(env)

    env
    |> builder.text_edit_snippet(insert_text, range, builder_opts)
    |> builder.set_sort_scope(SortScope.variable())
  end

  def translate(%Candidate.StructField{} = struct_field, builder, %Env{} = env) do
    builder.plain_text(env, struct_field.name,
      detail: struct_field.type_spec,
      label: struct_field.name,
      kind: CompletionItemKind.field()
    )
  end

  def edit_range(env) do
    prefix_end = env.position.character

    case Code.Fragment.cursor_context(env.prefix) do
      {:local_or_var, field_char} ->
        edit_begin = env.position.character - length(field_char)
        {edit_begin, prefix_end}

      _ ->
        {prefix_end, prefix_end}
    end
  end
end
