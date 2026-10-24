defmodule Expert.Search.Indexer.BeamFile do
  @moduledoc """
  Reads a BEAM file's metadata.

  Erlang's `:beam_lib` creates atoms when it reads beam files. The implementation
  here avoids doing so and returns strings instead.
  """

  alias Expert.Search.Indexer.ETF

  @type exports :: [{String.t(), arity()}]

  @spec read(binary()) :: {:ok, String.t(), exports(), {:ok, map()} | :error} | :error
  def read(beam) when is_binary(beam) do
    with {:ok, chunks} <- chunks(beam),
         {:ok, atoms} <- atoms(chunks),
         {:ok, exports} <- exports(chunks, atoms) do
      {:ok, elem(atoms, 0), exports, debug_info(chunks)}
    end
  end

  defp chunks(<<"FOR1", _size::32, "BEAM", chunks::binary>>), do: chunks(chunks, %{})
  defp chunks(_beam), do: :error

  defp chunks(<<id::binary-size(4), size::32, rest::binary>>, chunks) do
    case rest do
      <<data::binary-size(^size), rest::binary>> ->
        chunks(drop_padding(rest, size), Map.put(chunks, id, data))

      _truncated ->
        :error
    end
  end

  defp chunks(<<>>, chunks), do: {:ok, chunks}
  defp chunks(_rest, _chunks), do: :error

  defp drop_padding(rest, size) do
    padding = rem(4 - rem(size, 4), 4)

    case rest do
      <<_padding::binary-size(^padding), rest::binary>> -> rest
      _end_of_file -> <<>>
    end
  end

  defp atoms(%{"AtU8" => table}), do: atoms(table, :utf8)
  defp atoms(%{"Atom" => table}), do: atoms(table, :latin1)
  defp atoms(_chunks), do: :error

  # A negative count means some name is longer than 255 bytes, and every name
  # is then prefixed with a variable-length size.
  defp atoms(<<count::32-signed, names::binary>>, encoding) when count < 0 do
    long_names(names, encoding, [])
  end

  defp atoms(<<_count::32, names::binary>>, encoding), do: names(names, encoding, [])
  defp atoms(_table, _encoding), do: :error

  defp names(<<size, name::binary-size(size), rest::binary>>, encoding, names) do
    names(rest, encoding, [name(name, encoding) | names])
  end

  defp names(<<>>, _encoding, names), do: {:ok, names |> Enum.reverse() |> List.to_tuple()}
  defp names(_rest, _encoding, _names), do: :error

  defp long_names(<<size::4, 0::1, _tag::3, rest::binary>>, encoding, names) do
    long_name(size, rest, encoding, names)
  end

  defp long_names(<<high::3, 0::1, 1::1, _tag::3, low, rest::binary>>, encoding, names) do
    long_name(Bitwise.bsl(high, 8) + low, rest, encoding, names)
  end

  defp long_names(<<>>, _encoding, names), do: {:ok, names |> Enum.reverse() |> List.to_tuple()}
  defp long_names(_rest, _encoding, _names), do: :error

  defp long_name(size, rest, encoding, names) do
    case rest do
      <<name::binary-size(^size), rest::binary>> ->
        long_names(rest, encoding, [name(name, encoding) | names])

      _rest ->
        :error
    end
  end

  defp name(name, :utf8), do: name
  defp name(name, :latin1), do: :unicode.characters_to_binary(name, :latin1)

  defp exports(%{"ExpT" => <<_count::32, entries::binary>>}, atoms) do
    {:ok,
     for(<<index::32, arity::32, _label::32 <- entries>>, do: {elem(atoms, index - 1), arity})}
  end

  defp exports(_chunks, _atoms), do: :error

  defp debug_info(%{"Dbgi" => chunk}) do
    case ETF.decode(chunk) do
      {:ok, {"debug_info_v1", "elixir_erl", {"elixir_v1", %{} = metadata, _specs}}} ->
        {:ok, metadata}

      _other_or_none ->
        :error
    end
  end

  defp debug_info(_chunks), do: :error
end
