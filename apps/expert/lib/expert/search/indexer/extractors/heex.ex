defmodule Expert.Search.Indexer.Extractors.Heex do
  @moduledoc """
  Replaces a `~H` template with its Elixir code so that the other extractors
  index that code.

  The code is parsed from a source that has it at its position in the document,
  with whitespace instead of the markup around it. Assigns become variables, so
  they aren't indexed as module attributes.
  """

  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Ast.Heex

  @separated_types [:expr, :end_expr, :interpolation]
  @standalone_types [:expr, :interpolation]

  def extract({:sigil_H, _meta, _args} = sigil, %Reducer{}) do
    with {:ok, template} <- Heex.template(sigil),
         {:ok, events} <- Heex.scan(template.content) do
      {:ok, [], {:__block__, [], code(events, template)}}
    else
      :error -> :ignored
    end
  end

  def extract(_ast, _reducer), do: :ignored

  defp code(events, template) do
    spans =
      for {type, code, start} <- events do
        {type, Heex.document_code(template, code), Heex.to_document(template, start)}
      end

    case parse(spans) do
      {:ok, ast} ->
        [ast]

      :error ->
        for {type, _code, _start} = span <- spans,
            type in @standalone_types,
            {:ok, ast} <- [parse([span])],
            do: ast
    end
  end

  defp parse(spans) do
    spans
    |> masked_source()
    |> Ast.from()
    |> case do
      {:ok, ast, _comments} -> {:ok, assigns_as_variables(ast)}
      _ -> :error
    end
  end

  defp masked_source(spans) do
    {source, _position} =
      Enum.reduce(spans, {[], {1, 1}}, fn {type, code, start}, {source, position} ->
        finish = Heex.advance_over(start, code)

        {separator, finish} =
          if type in @separated_types,
            do: {";", Heex.advance_over(finish, ";")},
            else: {"", finish}

        {[source, padding(position, start), code, separator], finish}
      end)

    IO.iodata_to_binary(source)
  end

  defp padding({line, column}, {line, target_column}),
    do: String.duplicate(" ", target_column - column)

  defp padding({line, _column}, {target_line, target_column}) when target_line > line,
    do: String.duplicate("\n", target_line - line) <> String.duplicate(" ", target_column - 1)

  defp assigns_as_variables(ast) do
    Macro.prewalk(ast, fn
      {:@, _meta, [{name, meta, context}]} when is_atom(name) and is_atom(context) ->
        {name, meta, nil}

      other ->
        other
    end)
  end
end
