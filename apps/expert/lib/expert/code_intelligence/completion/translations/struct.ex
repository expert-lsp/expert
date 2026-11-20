defmodule Expert.CodeIntelligence.Completion.Translations.Struct do
  alias Forge.Ast.Env
  alias Forge.Formats
  alias GenLSP.Enumerations.CompletionItemKind

  def completion(%Env{} = _env, _builder, _module_name, _full_name, 0) do
    nil
  end

  def completion(%Env{} = env, builder, module_name, full_name, more) when is_integer(more) do
    singular = "${count} more struct"
    plural = "${count} more structs"

    builder_opts = [
      kind: CompletionItemKind.module(),
      label: "#{module_name}...(#{Formats.plural(more, singular, plural)})",
      detail: "#{full_name}."
    ]

    insert_text = "#{module_name}."
    range = edit_range(env)

    builder.text_edit_snippet(env, insert_text, range, builder_opts)
  end

  def completion(%Env{} = env, builder, struct_name, full_name) do
    builder_opts = [
      kind: CompletionItemKind.struct(),
      detail: "#{full_name}",
      label: "#{struct_name}"
    ]

    range = edit_range(env)

    insert_text =
      if add_curlies?(env) do
        struct_name <> "{$1}"
      else
        struct_name
      end

    builder.text_edit_snippet(env, insert_text, range, builder_opts)
  end

  defp add_curlies?(%Env{} = env) do
    if Env.in_context?(env, :struct_reference) do
      not String.contains?(env.suffix, "{")
    else
      false
    end
  end

  defp edit_range(%Env{} = env) do
    prefix_end = env.position.character

    edit_begin =
      case Code.Fragment.cursor_context(env.prefix) do
        {:struct, {:dot, {:alias, _typed_module}, _rest}} ->
          prefix_end

        {:struct, typed_module_name} ->
          beginning_of_edit(env, typed_module_name)

        {:local_or_var, [?_ | _rest] = typed} ->
          beginning_of_edit(env, typed)
      end

    {edit_begin, env.position.character}
  end

  defp beginning_of_edit(env, typed_module_name) do
    case left_offset_of(typed_module_name, ?.) do
      {:ok, offset} ->
        env.position.character - offset

      :error ->
        env.position.character - length(typed_module_name)
    end
  end

  defp left_offset_of(string, character) do
    string
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while(:error, fn
      {^character, index}, _ ->
        {:halt, {:ok, index}}

      _, acc ->
        {:cont, acc}
    end)
  end
end
