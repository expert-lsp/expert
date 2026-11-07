defmodule Expert.Search.Indexer.ETF do
  @moduledoc """
  Decodes external terms without creating atoms.
  """

  # ETF tags(see https://www.erlang.org/doc/apps/erts/erl_ext_dist.html)
  @version 131
  @compressed 80
  @small_integer_ext 97
  @integer_ext 98
  @new_float_ext 70
  @atom_ext 100
  @small_atom_ext 115
  @atom_utf8_ext 118
  @small_atom_utf8_ext 119
  @small_tuple_ext 104
  @large_tuple_ext 105
  @nil_ext 106
  @string_ext 107
  @list_ext 108
  @binary_ext 109
  @bit_binary_ext 77
  @small_big_ext 110
  @large_big_ext 111
  @export_ext 113
  @map_ext 116

  @spec decode(binary()) :: {:ok, term()} | :error
  def decode(<<@version, @compressed, _size::32, compressed::binary>>) do
    decode(<<@version, :zlib.uncompress(compressed)::binary>>)
  rescue
    ErlangError -> :error
  end

  def decode(<<@version, encoded::binary>>) do
    case term(encoded) do
      {term, <<>>} -> {:ok, term}
      _rest -> :error
    end
  rescue
    FunctionClauseError -> :error
    MatchError -> :error
  end

  def decode(_binary), do: :error

  defp term(<<@small_integer_ext, integer, rest::binary>>), do: {integer, rest}
  defp term(<<@integer_ext, integer::32-signed, rest::binary>>), do: {integer, rest}
  defp term(<<@new_float_ext, float::float-64, rest::binary>>), do: {float, rest}

  defp term(<<@atom_ext, size::16, name::binary-size(size), rest::binary>>),
    do: {atom(name, :latin1), rest}

  defp term(<<@small_atom_ext, size, name::binary-size(size), rest::binary>>),
    do: {atom(name, :latin1), rest}

  defp term(<<@atom_utf8_ext, size::16, name::binary-size(size), rest::binary>>),
    do: {atom(name, :utf8), rest}

  defp term(<<@small_atom_utf8_ext, size, name::binary-size(size), rest::binary>>),
    do: {atom(name, :utf8), rest}

  defp term(<<@small_tuple_ext, arity, rest::binary>>), do: tuple(arity, rest)
  defp term(<<@large_tuple_ext, arity::32, rest::binary>>), do: tuple(arity, rest)
  defp term(<<@nil_ext, rest::binary>>), do: {[], rest}

  defp term(<<@string_ext, size::16, characters::binary-size(size), rest::binary>>),
    do: {:binary.bin_to_list(characters), rest}

  defp term(<<@list_ext, length::32, rest::binary>>) do
    {elements, rest} = terms(length, rest, [])
    {tail, rest} = term(rest)
    {Enum.reduce(Enum.reverse(elements), tail, &[&1 | &2]), rest}
  end

  defp term(<<@binary_ext, size::32, binary::binary-size(size), rest::binary>>),
    do: {binary, rest}

  defp term(<<@bit_binary_ext, size::32, bits, data::binary-size(size), rest::binary>>) do
    prefix_size = size - 1
    <<prefix::binary-size(^prefix_size), last>> = data
    {<<prefix::binary, Bitwise.bsr(last, 8 - bits)::size(bits)>>, rest}
  end

  defp term(<<@small_big_ext, size, sign, digits::binary-size(size), rest::binary>>),
    do: {big(digits, sign), rest}

  defp term(<<@large_big_ext, size::32, sign, digits::binary-size(size), rest::binary>>),
    do: {big(digits, sign), rest}

  # Building the fun would create its module's and function's atoms.
  defp term(<<@export_ext, rest::binary>>) do
    {[module, function, arity], rest} = terms(3, rest, [])
    {{:fun, module, function, arity}, rest}
  end

  defp term(<<@map_ext, size::32, rest::binary>>) do
    {pairs, rest} = terms(size * 2, rest, [])
    {pairs |> Enum.chunk_every(2) |> Map.new(fn [key, value] -> {key, value} end), rest}
  end

  defp tuple(arity, rest) do
    {elements, rest} = terms(arity, rest, [])
    {List.to_tuple(elements), rest}
  end

  defp terms(0, rest, elements), do: {Enum.reverse(elements), rest}

  defp terms(count, rest, elements) do
    {element, rest} = term(rest)
    terms(count - 1, rest, [element | elements])
  end

  defp big(digits, 0), do: :binary.decode_unsigned(digits, :little)
  defp big(digits, 1), do: -:binary.decode_unsigned(digits, :little)

  defp atom("nil", _encoding), do: nil
  defp atom("true", _encoding), do: true
  defp atom("false", _encoding), do: false
  defp atom(name, :utf8), do: name
  defp atom(name, :latin1), do: :unicode.characters_to_binary(name, :latin1)
end
