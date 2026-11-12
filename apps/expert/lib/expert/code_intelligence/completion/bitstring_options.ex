defmodule Expert.CodeIntelligence.Completion.BitstringOptions do
  @moduledoc """
  Bitstring modifier candidates that may still follow the modifiers already
  written after `::`.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Matcher

  @types [:integer, :float, :bitstring, :binary, :utf8, :utf16, :utf32]
  @utf_types [:utf8, :utf16, :utf32]
  @type_aliases [bits: :bitstring, bytes: :binary]
  @signs [:signed, :unsigned]
  @endiannesses [:little, :big, :native]
  @endianness_types [:integer, :float, :utf16, :utf32]
  @order ~w(big binary bitstring integer float little native signed size unit unsigned utf8 utf16 utf32)a

  @doc """
  Returns the modifiers written before the cursor when the cursor path is in
  a bitstring segment's modifiers, or `:error`.
  """
  @spec written([Macro.t()]) :: {:ok, [Macro.t()]} | :error
  def written([cursor | parents]) do
    {modifiers, parents} = Enum.split_while(parents, &match?({:-, _, [_, _]}, &1))

    case parents do
      [{:"::", _, [_value, _type]}, {:<<>>, _, [_ | _]} | _] ->
        {:ok, Enum.flat_map(modifiers, fn {:-, _, [left, _right]} -> leaves(left, cursor) end)}

      _ ->
        :error
    end
  end

  def written(_path), do: :error

  @spec matching([Macro.t()], String.t()) :: [struct()]
  def matching(written, hint) do
    state =
      Enum.reduce(
        written,
        %{type: nil, sign: nil, endianness: nil, size: nil, unit: nil},
        &apply_modifier/2
      )

    available = available(state)

    for name <- @order,
        name in available,
        name = Atom.to_string(name),
        Matcher.match?(name, hint),
        do: %Candidate.BitstringOption{name: name, type: :bitstring_option}
  end

  defp leaves({:-, _, [left, right]}, cursor), do: leaves(left, cursor) ++ leaves(right, cursor)
  defp leaves(cursor, cursor), do: []
  defp leaves(modifier, _cursor), do: [modifier]

  defp apply_modifier({name, _, args}, state)
       when is_atom(name) and (is_atom(args) or is_list(args)) do
    name = Keyword.get(@type_aliases, name, name)

    cond do
      name in @types -> %{state | type: name}
      name in @signs -> %{state | sign: name}
      name in @endiannesses -> %{state | endianness: name}
      name == :size -> %{state | size: true}
      name == :unit -> %{state | unit: true}
      true -> state
    end
  end

  defp apply_modifier(_modifier, state), do: state

  defp available(state) do
    types(state) ++ signs(state) ++ endiannesses(state) ++ size_and_unit(state)
  end

  defp types(%{type: nil, sign: nil, endianness: nil} = state), do: without_utf(state, @types)
  defp types(%{type: nil, sign: nil} = state), do: without_utf(state, @endianness_types)
  defp types(%{type: nil}), do: [:integer]
  defp types(_state), do: []

  defp signs(%{type: type, sign: nil}) when type in [nil, :integer], do: @signs
  defp signs(_state), do: []

  defp endiannesses(%{type: type, endianness: nil}) when type in [nil, :integer, :utf16, :utf32],
    do: @endiannesses

  defp endiannesses(%{type: :float, endianness: nil}), do: [:little, :big]
  defp endiannesses(_state), do: []

  # Size and unit don't compile with the utf types.
  defp size_and_unit(%{type: type}) when type in @utf_types, do: []

  defp size_and_unit(state) do
    if(is_nil(state.size), do: [:size], else: []) ++ if(is_nil(state.unit), do: [:unit], else: [])
  end

  defp without_utf(%{size: nil, unit: nil}, types), do: types
  defp without_utf(_state, types), do: types -- @utf_types
end
