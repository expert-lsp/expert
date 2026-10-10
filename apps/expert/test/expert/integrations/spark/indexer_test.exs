defmodule Expert.Integrations.Spark.IndexerTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Integrations

  @tag :tmp_dir
  test "converts static function schemas to contextual completion metadata", %{tmp_dir: tmp_dir} do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true)

    on_exit(fn -> Code.compiler_options(compiler_options) end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        @doc spark_opts: [
          {1,
           [
             enabled?: [type: :boolean, doc: "Enables the operation"],
             private: [type: :string, private?: true]
           ]}
        ]
        def run(value, options \\\\ []), do: {value, options}
      end
      """)

    :code.purge(module)
    :code.delete(module)
    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    assert [entry] =
             Integrations.index_beam(
               project(),
               binary,
               %{module: module, attributes: attributes},
               Path.join(tmp_dir, "fixture.ex")
             )

    assert %{
             kind: :dsl,
             contexts: [
               %{
                 mfa: %{module: target, name: "run", arity: 2},
                 argument: 1,
                 scope: 0
               }
             ],
             scopes: %{
               0 => %{
                 entries: [
                   %{
                     kind: :keyword,
                     name: "enabled?",
                     doc: "Enables the operation",
                     value_scope: 1
                   }
                 ],
                 data: []
               },
               1 => %{
                 entries: [
                   %{kind: :literal, value: true},
                   %{kind: :literal, value: false}
                 ],
                 data: []
               }
             }
           } = entry.metadata.payload

    assert target == Atom.to_string(module)
  end
end
