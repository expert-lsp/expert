defmodule Expert.Search.Indexer.ArgumentNames do
  @moduledoc """
  Names the arguments of a function head for one of its arities. Elixir fills
  the arguments with defaults from left to right as the arity grows.
  """

  @spec for_arity([Macro.t()], arity()) :: [String.t()]
  def for_arity(args, arity) do
    defaults = arity - Enum.count(args, &(not match?({:\\, _, _}, &1)))

    {names, _} =
      args
      |> Enum.with_index(1)
      |> Enum.flat_map_reduce(defaults, fn
        {{:\\, _, [arg, _default]}, index}, defaults when defaults > 0 ->
          {[argument_name(arg, index)], defaults - 1}

        {{:\\, _, _}, _index}, defaults ->
          {[], defaults}

        {arg, index}, defaults ->
          {[argument_name(arg, index)], defaults}
      end)

    names
  end

  defp argument_name({:__block__, _, [atom]}, _index) when is_atom(atom), do: inspect(atom)
  defp argument_name(atom, _index) when is_atom(atom), do: inspect(atom)
  defp argument_name(arg, index), do: variable_name(arg) || "arg_#{index}"

  defp variable_name({name, _, context}) when is_atom(name) and is_atom(context) do
    Atom.to_string(name)
  end

  defp variable_name({:=, _, sides}), do: Enum.find_value(sides, &variable_name/1)
  defp variable_name(_), do: nil
end
