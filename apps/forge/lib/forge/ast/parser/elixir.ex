defmodule Forge.Ast.Parser.Elixir do
  @moduledoc false

  defp opts do
    [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      unescape: false
    ]
  end

  def string_to_quoted(string) when is_binary(string) do
    Code.string_to_quoted_with_comments(string, opts())
  end

  def container_cursor_to_quoted(fragment) when is_binary(fragment) do
    Code.Fragment.container_cursor_to_quoted(fragment, opts())
  end
end
