defmodule Expert.Search.Indexer.BeamFileTest do
  use ExUnit.Case, async: true

  alias Expert.Search.Indexer.BeamFile

  @moduletag :tmp_dir

  describe "read/1" do
    test "reads what :beam_lib reads, with names as strings", %{tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, :"Read#{System.unique_integer([:positive])}")

      source = """
      defmodule #{inspect(module)} do
        defstruct [:field]
        def fun(a, b \\\\ nil), do: {a, b}
        defmacro mac(ast), do: ast
        defdelegate trim(s), to: String
      end
      """

      beam = compile!(tmp_dir, module, source)

      assert {:ok, name, exports, {:ok, metadata}} = BeamFile.read(beam)

      {:ok, {^module, [exports: expected_exports, debug_info: debug_info]}} =
        :beam_lib.chunks(beam, [:exports, :debug_info])

      {:debug_info_v1, backend, data} = debug_info
      {:ok, expected_metadata} = backend.debug_info(:elixir_v1, module, data, [])

      assert name == Atom.to_string(module)
      assert Enum.sort(exports) == Enum.sort(stringify(expected_exports))
      assert metadata == stringify(expected_metadata)
    end

    test "reports no debug info for a BEAM compiled without it", %{tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, :"NoDebug#{System.unique_integer([:positive])}")

      beam =
        compile!(tmp_dir, module, "defmodule #{inspect(module)}, do: def(fun, do: :ok)",
          debug_info: false
        )

      assert {:ok, name, exports, :error} = BeamFile.read(beam)
      assert name == Atom.to_string(module)
      assert {"fun", 0} in exports
    end

    test "rejects files that aren't BEAMs" do
      assert :error = BeamFile.read("FOR1 but not a beam")
      assert :error = BeamFile.read(<<"FOR1", 0::32, "BEAM", "AtU8", 100::32, 1, 2>>)
    end
  end

  defp compile!(tmp_dir, module, source, options \\ []) do
    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: Keyword.get(options, :debug_info, true))
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    [{^module, beam}] = Code.compile_string(source, Path.join(tmp_dir, "source.ex"))
    :code.purge(module)
    :code.delete(module)
    beam
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
