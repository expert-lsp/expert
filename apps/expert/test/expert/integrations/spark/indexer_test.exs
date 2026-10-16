defmodule Expert.Integrations.Spark.IndexerTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Integrations.SemanticMetadata
  alias Expert.Integrations.Spark.Indexer
  alias Expert.Test.SemanticMetadataCase

  @moduletag :tmp_dir

  test "documents the public options of an argument", %{tmp_dir: tmp_dir} do
    {module, documents} =
      index(tmp_dir, """
      @doc spark_opts: [
        {1,
         [
           enabled?: [type: :boolean, doc: "Enables the operation"],
           secret: [type: :string, private?: true]
         ]}
      ]
      def run(value, options), do: {value, options}
      """)

    assert documents == [
             %{
               contexts: [%{mfa: {module, :run, 2}, argument: 1, scope: 0}],
               scopes: %{
                 0 => %{
                   entries: [
                     %{
                       kind: :keyword,
                       name: :enabled?,
                       doc: "Enables the operation",
                       value_scope: 1
                     }
                   ]
                 },
                 1 => %{
                   entries: [%{kind: :literal, value: true}, %{kind: :literal, value: false}]
                 }
               }
             }
           ]
  end

  test "documents an argument at every arity that has it", %{tmp_dir: tmp_dir} do
    {module, documents} =
      index(tmp_dir, """
      @doc spark_opts: [{1, [name: [type: :atom]]}]
      def run(value, options \\\\ [], extra \\\\ nil), do: {value, options, extra}
      """)

    assert [[%{mfa: {^module, :run, 2}}], [%{mfa: {^module, :run, 3}}]] =
             Enum.map(documents, & &1.contexts)
  end

  test "documents the values of choices, alternatives and nested keyword lists", %{
    tmp_dir: tmp_dir
  } do
    {_module, [%{scopes: scopes}]} =
      index(tmp_dir, """
      @doc spark_opts: [
        {0,
         [
           mode: [type: {:one_of, [:fast, :slow]}],
           limit: [type: {:or, [:boolean, {:in, [:none, true]}]}],
           nested: [type: {:keyword_list, [depth: [type: :integer]]}]
         ]}
      ]
      def run(options), do: options
      """)

    assert scopes == %{
             0 => %{
               entries: [
                 %{kind: :keyword, name: :mode, value_scope: 1},
                 %{kind: :keyword, name: :limit, value_scope: 2},
                 %{kind: :keyword, name: :nested, value_scope: 3}
               ]
             },
             1 => %{entries: [%{kind: :literal, value: :fast}, %{kind: :literal, value: :slow}]},
             2 => %{
               entries: [
                 %{kind: :literal, value: true},
                 %{kind: :literal, value: false},
                 %{kind: :literal, value: :none}
               ]
             },
             3 => %{entries: [%{kind: :keyword, name: :depth}]}
           }
  end

  test "skips a module that publishes its own semantic metadata", %{tmp_dir: tmp_dir} do
    assert {_module, []} =
             index(tmp_dir, """
             Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
               accumulate: true,
               persist: true
             )

             @elixir_semantic_metadata {
               :elixir_semantic_metadata_v1,
               %{
                 contexts: [%{mfa: {__MODULE__, :run, 1}, argument: 0, scope: :options}],
                 scopes: %{options: %{entries: [%{kind: :keyword, name: :name}]}}
               }
             }

             @doc spark_opts: [{0, [name: [type: :atom]]}]
             def run(options), do: options
             """)
  end

  defp index(tmp_dir, body) do
    module = SemanticMetadataCase.unique_module("Fixture")
    source = "defmodule #{inspect(module)} do\n#{body}\nend"
    {^module, beam_path} = SemanticMetadataCase.compile_beam!(tmp_dir, source)
    binary = File.read!(beam_path)
    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    entries =
      Indexer.index(project(), binary, %{module: module, attributes: attributes}, "/lib.ex")

    documents =
      for %{subject: subject, metadata: %{payload: document}} <- entries,
          String.starts_with?(subject, SemanticMetadata.Indexer.subject_prefix()),
          do: document

    {module, documents}
  end
end
