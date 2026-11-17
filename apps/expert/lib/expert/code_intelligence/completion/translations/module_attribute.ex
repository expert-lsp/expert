defmodule Expert.CodeIntelligence.Completion.Translations.ModuleAttribute do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document.Position
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.ModuleAttribute do
    def translate(attribute, builder, %Env{} = env) do
      Translations.ModuleAttribute.translate(attribute, builder, env)
    end
  end

  def translate(%Candidate.ModuleAttribute{name: "@moduledoc"}, builder, env) do
    doc_snippet = ~s'''
    @moduledoc """
    $0
    """
    '''

    case fetch_range(env) do
      {:ok, range} ->
        with_doc =
          builder.text_edit_snippet(env, doc_snippet, range,
            detail: "Document public module",
            kind: CompletionItemKind.property(),
            label: "@moduledoc"
          )

        without_doc =
          builder.text_edit(env, "@moduledoc false", range,
            detail: "Mark as private",
            kind: CompletionItemKind.property(),
            label: "@moduledoc false"
          )

        [with_doc, without_doc]

      :error ->
        :skip
    end
  end

  def translate(%Candidate.ModuleAttribute{name: "@doc"}, builder, env) do
    doc_snippet = ~s'''
    @doc """
    $0
    """
    '''

    case fetch_range(env) do
      {:ok, range} ->
        with_doc =
          builder.text_edit_snippet(env, doc_snippet, range,
            detail: "Document public function",
            kind: CompletionItemKind.property(),
            label: "@doc"
          )

        without_doc =
          builder.text_edit(env, "@doc false", range,
            detail: "Mark as private",
            kind: CompletionItemKind.property(),
            label: "@doc false"
          )

        [with_doc, without_doc]

      :error ->
        :skip
    end
  end

  def translate(%Candidate.ModuleAttribute{name: "@spec"}, builder, env) do
    case fetch_range(env) do
      {:ok, range} ->
        [
          maybe_specialized_spec_snippet(builder, env, range),
          basic_spec_snippet(builder, env, range)
        ]

      :error ->
        :skip
    end
  end

  def translate(%Candidate.ModuleAttribute{} = attribute, builder, env) do
    case fetch_range(env) do
      {:ok, range} ->
        builder.text_edit(env, attribute.name, range,
          detail: "module attribute",
          kind: CompletionItemKind.constant(),
          label: attribute.name
        )

      :error ->
        :skip
    end
  end

  defp fetch_range(%Env{} = env) do
    case fetch_at_op_on_same_line(env) do
      {:ok, {:at_op, _, {_line, char}}} ->
        {:ok, {char, env.position.character}}

      _ ->
        :error
    end
  end

  defp fetch_at_op_on_same_line(%Env{} = env) do
    Enum.reduce_while(Env.prefix_tokens(env), :error, fn
      {:at_op, _, _} = at_op, _acc ->
        {:halt, {:ok, at_op}}

      {:eol, _, _}, _acc ->
        {:halt, :error}

      _, acc ->
        {:cont, acc}
    end)
  end

  defp maybe_specialized_spec_snippet(builder, %Env{} = env, range) do
    with {:ok, %Position{} = position} <- Env.next_significant_position(env),
         {:ok, [{maybe_def, _, call_args} | _]} when maybe_def in [:def, :defp] <-
           Ast.path_at(env.analysis, position),
         {:ok, function_name, args} <- fetch_function_name_and_args(call_args) do
      specialized_spec_snippet(builder, env, range, function_name, args)
    else
      _ -> nil
    end
  end

  defp specialized_spec_snippet(builder, env, range, function_name, args) do
    name = to_string(function_name)

    args_snippet =
      case args do
        nil ->
          ""

        list ->
          Enum.map_join(1..length(list), ", ", &"${#{&1}:term()}")
      end

    snippet = ~s"""
    @spec #{name}(#{args_snippet}) :: ${0:term()}
    """

    env
    |> builder.text_edit_snippet(snippet, range,
      detail: "Typespec",
      kind: CompletionItemKind.property(),
      label: "@spec #{name}"
    )
    |> builder.set_sort_scope(SortScope.global(false, 0))
  end

  defp basic_spec_snippet(builder, env, range) do
    snippet = ~S"""
    @spec ${1:function}(${2:term()}) :: ${3:term()}
    def ${1:function}(${4:args}) do
      $0
    end
    """

    env
    |> builder.text_edit_snippet(snippet, range,
      detail: "Typespec",
      kind: CompletionItemKind.property(),
      label: "@spec"
    )
    |> builder.set_sort_scope(SortScope.global(false, 1))
  end

  defp fetch_function_name_and_args([{:when, _, [{function_name, _, args} | _]}, _])
       when is_atom(function_name) and is_list(args) do
    {:ok, function_name, args}
  end

  defp fetch_function_name_and_args([{function_name, _, args}, _])
       when is_atom(function_name) and is_list(args) do
    {:ok, function_name, args}
  end

  defp fetch_function_name_and_args([{function_name, _, nil}, _]) when is_atom(function_name) do
    {:ok, function_name, nil}
  end

  defp fetch_function_name_and_args(_) do
    :error
  end
end
