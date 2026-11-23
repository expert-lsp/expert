defmodule Expert.CodeIntelligence.Completion.Builder do
  @moduledoc """
  Completion builder.

  For broader compatibility and control, this builder always creates text
  edits, as opposed to simple text insertions. This allows the replacement
  range to be adjusted based on the kind of completion.

  When completions are built using `plain_text/3` or `snippet/3`, the
  replacement range will be determined by the preceding token.
  """

  alias Expert.CodeIntelligence.Completion.SortScope
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Enumerations.InsertTextFormat
  alias GenLSP.Enumerations.MarkupKind
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.MarkupContent

  @doc "Fields found in `t:Expert.Protocol.Types.Completion.Item.t()`"
  @type item_opts :: keyword()

  @type t :: module()

  @type line_range :: {start_character :: pos_integer, end_character :: pos_integer}

  @spec snippet(Env.t(), String.t(), item_opts) :: CompletionItem.t()
  def snippet(%Env{} = env, text, options \\ []) do
    range = prefix_range(env, text)
    text_edit_snippet(env, text, range, options)
  end

  @spec plain_text(Env.t(), String.t(), item_opts) :: CompletionItem.t()
  def plain_text(%Env{} = env, text, options \\ []) do
    range = prefix_range(env, text)
    text_edit(env, text, range, options)
  end

  @spec text_edit(Env.t(), String.t(), line_range, item_opts) :: CompletionItem.t()
  def text_edit(%Env{} = env, text, {start_char, end_char}, options \\ []) do
    line_number = env.position.line

    range =
      Range.new(
        Position.new(env.document, line_number, start_char),
        Position.new(env.document, line_number, end_char)
      )

    edits = Document.Changes.new(env.document, Edit.new(text, range))

    options = Keyword.put(options, :text_edit, edits)

    CompletionItem
    |> struct(options)
    |> markdown_docs()
    |> set_sort_scope(SortScope.default())
  end

  @spec text_edit_snippet(Env.t(), String.t(), line_range, item_opts) :: CompletionItem.t()
  def text_edit_snippet(%Env{} = env, text, {start_char, end_char}, options \\ []) do
    snippet = String.trim_trailing(text, "\n")
    line_number = env.position.line

    range =
      Range.new(
        Position.new(env.document, line_number, start_char),
        Position.new(env.document, line_number, end_char)
      )

    edits = Document.Changes.new(env.document, Edit.new(snippet, range))

    option =
      options
      |> Keyword.put(:text_edit, edits)
      |> Keyword.put(:insert_text_format, InsertTextFormat.snippet())

    CompletionItem
    |> struct(option)
    |> markdown_docs()
    |> set_sort_scope(SortScope.default())
  end

  @spec fallback(any, any) :: any
  def fallback(nil, fallback), do: fallback
  def fallback("", fallback), do: fallback
  def fallback(detail, _), do: detail

  @spec set_sort_scope(CompletionItem.t(), sort_scope :: String.t()) :: CompletionItem.t()
  def set_sort_scope(item, default \\ SortScope.default())

  def set_sort_scope(%CompletionItem{} = item, sort_scope)
      when is_binary(sort_scope) do
    stripped_sort_text =
      item.sort_text
      |> fallback(item.label)
      |> strip_sort_text()

    sort_text = "0#{sort_scope}_#{stripped_sort_text}"
    %CompletionItem{item | sort_text: sort_text}
  end

  # private

  defp prefix_range(%Env{} = env, text) do
    end_char = env.position.character
    start_char = max(end_char - prefix_length(env, text), 1)
    {start_char, end_char}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp prefix_length(%Env{} = env, text) do
    case Code.Fragment.cursor_context(env.prefix) do
      {:alias, alias_charlist} ->
        alias_charlist
        |> :string.split(~c".", :all)
        |> List.last()
        |> length()

      {:alias, {:local_or_var, _}, alias_charlist} ->
        length(alias_charlist)

      {:alias, {:module_attribute, _}, alias_charlist} ->
        length(alias_charlist)

      {:dot, _inside_dot, charlist} ->
        length(charlist)

      {:dot_arity, _inside_dot, charlist} ->
        length(charlist)

      {:dot_call, _inside_dot, _charlist} ->
        0

      :expr ->
        String.length(env.prefix)

      {:local_or_var, local} ->
        length(local)

      {:local_arity, local} ->
        length(local)

      {:local_call, call} ->
        length(call)

      {:module_attribute, attr} ->
        length(attr)

      {:operator, operator} ->
        # the operator is only part of the prefix when the completion
        # continues it, like `+` being completed to `++`
        if String.starts_with?(text, List.to_string(operator)) do
          length(operator)
        else
          0
        end

      {:operator_arity, _} ->
        0

      {:operator_call, _} ->
        0

      {:sigil, sigil} ->
        # The sigil charlist doesn't include the leading `~`
        length(sigil) + 1

      {:struct, struct} ->
        length(struct)

      :none ->
        0

      {:unquoted_atom, atom} ->
        # add one to include the leading colon, which isn't included
        # in the atom charlist
        length(atom) + 1
    end
  end

  @sort_prefix_re ~r/^[0-9_]+/
  defp strip_sort_text(sort_text) do
    String.replace(sort_text, @sort_prefix_re, "")
  end

  defp markdown_docs(%CompletionItem{} = item) do
    case item.documentation do
      doc when is_binary(doc) ->
        %{item | documentation: %MarkupContent{kind: MarkupKind.markdown(), value: doc}}

      _ ->
        item
    end
  end
end
