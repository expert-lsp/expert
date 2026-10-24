defmodule Expert.Search.Indexer.ETFTest do
  use ExUnit.Case, async: true

  alias Expert.Search.Indexer.ETF

  describe "decode/1" do
    test "decodes every kind of term the compiler writes, with atoms as strings" do
      term = %{
        atoms: [:def, nil, true, false, :"with space", :ünïcode],
        integers: [0, 255, 256, -1, 1_000_000, Bitwise.bsl(1, 70), -Bitwise.bsl(1, 70)],
        floats: [1.5, -0.25],
        tuples: [{}, {:ok, 1}, List.to_tuple(Enum.to_list(1..300))],
        lists: [[], [1, 2, 3], ~c"abc", [1 | 2], Enum.to_list(1..70_000)],
        binaries: ["", "bin", <<1, 2, 3>>, <<5::3>>, <<255, 1::1>>],
        map: %{{:key, 1} => [value: "x"]}
      }

      assert {:ok, decoded} = ETF.decode(:erlang.term_to_binary(term))
      assert decoded == stringify(term)

      assert {:ok, ^decoded} =
               ETF.decode(:erlang.term_to_binary(term, [:compressed]))
    end

    test "decodes an external fun as its name" do
      assert {:ok, {:fun, "Elixir.Function", "identity", 1}} =
               ETF.decode(:erlang.term_to_binary(&Function.identity/1))
    end

    test "decodes the atom encodings older compilers wrote" do
      assert {:ok, {"abc", "d", "é"}} =
               ETF.decode(<<131, 104, 3, 100, 0, 3, "abc", 115, 1, "d", 100, 0, 1, 233>>)
    end

    test "rejects terms it can't decode" do
      assert :error = ETF.decode("not a term")
      assert :error = ETF.decode(<<131, 80, 0, 0, 0, 1, "not zlib">>)
      assert :error = ETF.decode(:erlang.term_to_binary(self()))
      assert :error = ETF.decode(<<131, 97, 1, 97, 2>>)
    end
  end

  defp stringify(term) when term in [nil, true, false], do: term
  defp stringify(term) when is_atom(term), do: Atom.to_string(term)
  defp stringify([head | tail]), do: [stringify(head) | stringify(tail)]

  defp stringify(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&stringify/1) |> List.to_tuple()

  defp stringify(term) when is_map(term),
    do: term |> :maps.to_list() |> Map.new(fn {k, v} -> {stringify(k), stringify(v)} end)

  defp stringify(term), do: term
end
