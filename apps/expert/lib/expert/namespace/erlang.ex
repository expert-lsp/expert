defmodule Expert.Namespace.Erlang do
  @moduledoc """
  Utilities for reading and writing erlang terms from and to text
  """

  def path_to_term(file_path) do
    with {:ok, [term]} <- :file.consult(file_path) do
      {:ok, term}
    end
  end

  def path_to_ast(file_path) do
    path_charlist = String.to_charlist(file_path)

    with {:ok, [app]} <- :file.consult(path_charlist) do
      ast_string = inspect(app)
      Code.string_to_quoted(ast_string)
    end
  end

  def term_to_string(term) do
    ~c"~p.~n"
    |> :io_lib.format([term])
    |> :lists.flatten()
    |> List.to_string()
  end

  def ast_to_string(elixir_ast) do
    elixir_ast
    |> Code.eval_quoted()
    |> term_to_string()
  end
end
