defmodule Expert.Integrations.SemanticMetadata.Sigil do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document.Position

  @heredoc_delimiters ["\"\"\"", "'''"]
  @closing_delimiters %{"(" => ")", "[" => "]", "{" => "}", "<" => ">"}

  def at(%Analysis{} = analysis, %Position{} = position) do
    %{line: line, character: character} = Positions.cursor(analysis.document, position)
    position = %Position{position | character: character}
    cursor = {line, character}

    with {:ok, path} <- Ast.path_at(analysis, position),
         %{} = sigil <- Enum.find_value(path, &sigil/1),
         true <- within?(cursor, sigil.content) do
      {:ok, sigil}
    else
      _ -> :error
    end
  end

  defp sigil({name, meta, [{:<<>>, _, _}, modifiers]} = node)
       when is_atom(name) and is_list(modifiers) do
    with "sigil_" <> sigil_name <- Atom.to_string(name),
         delimiter when is_binary(delimiter) <- meta[:delimiter],
         %{
           start: [line: start_line, column: start_column],
           end: [line: end_line, column: end_column]
         } <-
           Sourceror.get_range(node) do
      content_start =
        if delimiter in @heredoc_delimiters do
          {start_line + 1, 1}
        else
          # Skips `~`, the name and the opening delimiter.
          {start_line, start_column + 1 + String.length(sigil_name) + String.length(delimiter)}
        end

      closing = Map.get(@closing_delimiters, delimiter, delimiter)
      content_end = {end_line, end_column - length(modifiers) - String.length(closing)}

      %{
        name: sigil_name,
        range: range({start_line, start_column}, {end_line, end_column}),
        content: range(content_start, content_end)
      }
    else
      _ -> nil
    end
  end

  defp sigil(_node), do: nil

  defp within?(cursor, %{start: start, end: stop}) do
    cursor >= {start.line, start.character} and cursor <= {stop.line, stop.character}
  end

  defp range({start_line, start_character}, {end_line, end_character}) do
    %{
      start: %{line: start_line, character: start_character},
      end: %{line: end_line, character: end_character}
    }
  end
end
