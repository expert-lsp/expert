defmodule Engine.Module.LoaderTest do
  use ExUnit.Case, async: false

  alias Engine.Module.Loader

  @tag :tmp_dir
  test "loads a changed BEAM before the next call", %{tmp_dir: tmp_dir} do
    module = Module.concat(__MODULE__, "Provider#{System.unique_integer([:positive])}")
    [{^module, first_binary}] = compile_provider(module, :first)
    :code.purge(module)
    :code.delete(module)
    [{^module, second_binary}] = compile_provider(module, :second)
    beam_path = Path.join(tmp_dir, "#{module}.beam")
    File.write!(beam_path, second_binary)
    true = :code.add_patha(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(tmp_dir))
    end)

    :code.purge(module)
    :code.delete(module)

    assert {:module, ^module} =
             :code.load_binary(module, String.to_charlist(beam_path), first_binary)

    assert :first == module.value()
    assert :modified == :code.module_status(module)
    assert {:module, ^module} = Loader.ensure_fresh(module)
    assert :second == module.value()
    assert :loaded == :code.module_status(module)
  end

  defp compile_provider(module, value) do
    Code.compile_string("""
    defmodule #{inspect(module)} do
      def value, do: #{inspect(value)}
    end
    """)
  end
end
