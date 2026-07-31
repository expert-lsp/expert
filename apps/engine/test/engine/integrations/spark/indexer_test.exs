defmodule Engine.Integrations.Spark.IndexerTest do
  use ExUnit.Case, async: false

  alias Engine.Integrations
  alias Forge.Search.Indexer.Entry

  setup_all do
    if !Code.ensure_loaded?(Spark.Dsl.Extension) do
      Code.compile_string("""
      defmodule Spark.Dsl.Extension do
        @callback sections() :: list()
        @callback dsl_patches() :: list()
        @callback add_extensions() :: list()
      end
      """)

      on_exit(fn ->
        :code.purge(Spark.Dsl.Extension)
        :code.delete(Spark.Dsl.Extension)
      end)
    end

    :ok
  end

  @tag :tmp_dir
  test "indexes DSL sections, entities, options, values, and documentation", %{tmp_dir: tmp_dir} do
    start_supervised!(Engine.ApplicationCache)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: true)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    suffix = System.unique_integer([:positive])
    dsl = Module.concat(__MODULE__, "Dsl#{suffix}")
    extension = Module.concat(__MODULE__, "Extension#{suffix}")

    [{^extension, extension_binary}] =
      Code.compile_string("""
      defmodule #{inspect(extension)} do
        @behaviour Spark.Dsl.Extension

        def add_extensions, do: []

        def sections do
          [
            %{
              name: :attributes,
              docs: "Attribute definitions",
              entities: [
                %{
                  name: :attribute,
                  docs: "Declares an attribute",
                   args: [:name, :type],
                   schema: [
                    type: [type: {:spark_type, #{inspect(dsl)}, :builtins, []}],
                    constraints: [
                      type: :keyword_list,
                      keys: [max_length: [type: :non_neg_integer]]
                    ],
                    private?: [type: :boolean, default: false],
                    mode: [type: {:one_of, [:read, :write]}]
                  ]
                }
              ]
            }
          ]
        end

        def dsl_patches do
          [%{section_path: [:attributes], entity: %{name: :calculation, args: [], schema: []}}]
        end
      end
      """)

    [{^dsl, dsl_binary}] =
      Code.compile_string("""
      defmodule #{inspect(dsl)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        Module.register_attribute(__MODULE__, :spark_default_extensions, persist: true)
        Module.register_attribute(__MODULE__, :spark_extension_kinds, persist: true)
        @spark_dsl true
        @spark_default_extensions [#{inspect(extension)}]
        @spark_extension_kinds [:extensions]

        def default_extensions, do: [#{inspect(extension)}]
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []
        def short_names, do: [string: #{inspect(extension)}]
        def opt_schema, do: [otp_app: [type: :atom, doc: "OTP application"]]
      end
      """)

    extension_metadata =
      extension_binary
      |> index(extension, Path.join(tmp_dir, "extension.ex"))
      |> metadata(Entry.integration_subject("spark", :extension, extension))

    assert [%{name: "attributes", documentation: "Attribute definitions", entities: [entity]}] =
             extension_metadata.sections

    assert entity.name == "attribute"
    assert entity.documentation == "Declares an attribute"
    assert Enum.map(entity.arguments, & &1.name) == ["name", "type"]

    assert entity.options |> Enum.find(&(&1.name == "type")) |> Map.fetch!(:type) == %{
             kind: :spark_type,
             behaviour: Atom.to_string(dsl),
             aliases: %{"string" => Atom.to_string(extension)}
           }

    assert %{
             kind: :keyword_list,
             options: [
               %{name: "max_length", type: %{kind: :unknown, value: ":non_neg_integer"}}
             ]
           } = entity.options |> Enum.find(&(&1.name == "constraints")) |> Map.fetch!(:type)

    assert Enum.find(entity.options, &(&1.name == "private?")).type == %{kind: :boolean}

    assert Enum.find(entity.options, &(&1.name == "mode")).type == %{
             kind: :choices,
             values: [
               %{label: ":read", insert_text: ":read"},
               %{label: ":write", insert_text: ":write"}
             ]
           }

    assert [%{section_path: ["attributes"], entity: %{name: "calculation"}}] =
             extension_metadata.patches

    dsl_metadata =
      dsl_binary
      |> index(dsl, Path.join(tmp_dir, "dsl.ex"))
      |> metadata(Entry.integration_subject("spark", :dsl, dsl))

    assert dsl_metadata.default_extensions == [Atom.to_string(extension)]
    assert dsl_metadata.extension_kinds == ["extensions"]

    assert [%{name: "otp_app", documentation: "OTP application", type: %{kind: :atom}}] =
             dsl_metadata.options
  end

  test "does not replace a module already loaded by the engine" do
    module = Module.concat(__MODULE__, "Loaded#{System.unique_integer([:positive])}")
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(compiler_options)
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, original_binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []
        def opt_schema, do: [source: [type: {:literal, :loaded}]]
        def marker, do: :original
      end
      """)

    [{^module, spark_binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []
        def opt_schema, do: [source: [type: {:literal, :indexed}]]
      end
      """)

    :code.purge(module)
    :code.delete(module)
    assert {:module, ^module} = :code.load_binary(module, ~c"original", original_binary)

    assert [] = index(spark_binary, module, "loaded.ex")
    assert module.marker() == :original
  end

  @tag :tmp_dir
  test "reloads updated metadata from the same dependency BEAM", %{tmp_dir: tmp_dir} do
    module = Module.concat(__MODULE__, "Updated#{System.unique_integer([:positive])}")
    beam_path = Path.join(tmp_dir, Atom.to_string(module) <> ".beam")
    code_path = String.to_charlist(tmp_dir)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(compiler_options)
      :code.purge(module)
      :code.delete(module)
      :code.del_path(code_path)
    end)

    [{^module, original_binary}] =
      Code.compile_string(dsl_source(module, :original))

    [{^module, updated_binary}] =
      Code.compile_string(dsl_source(module, :updated))

    File.write!(beam_path, original_binary)
    true = :code.add_patha(code_path)
    :code.purge(module)
    :code.delete(module)
    assert {:module, ^module} = Code.ensure_loaded(module)

    File.write!(beam_path, updated_binary)

    assert %{options: [%{type: %{values: [%{label: ":updated"}]}}]} =
             updated_binary
             |> index(module, "updated.ex")
             |> metadata(Entry.integration_subject("spark", :dsl, module))
  end

  test "rejects malformed callback metadata without crashing" do
    module = Module.concat(__MODULE__, "Malformed#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: [:invalid]
        def single_extension_kinds, do: []
        def opt_schema, do: []
      end
      """)

    assert [] = index(binary, module, "malformed.ex")
  end

  @tag :tmp_dir
  test "loads matching dependency modules to index their documentation", %{tmp_dir: tmp_dir} do
    module = Module.concat(__MODULE__, "Unloaded#{System.unique_integer([:positive])}")
    beam_path = Path.join(tmp_dir, Atom.to_string(module) <> ".beam")
    code_path = String.to_charlist(tmp_dir)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.del_path(code_path)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []
        def opt_schema, do: [source: [type: :atom, doc: "Source documentation"]]
      end
      """)

    File.write!(beam_path, binary)
    true = :code.add_patha(code_path)
    :code.purge(module)
    :code.delete(module)

    assert false == :code.is_loaded(module)

    assert %{options: [%{name: "source", documentation: "Source documentation"}]} =
             binary
             |> index(module, "unloaded.ex")
             |> metadata(Entry.integration_subject("spark", :dsl, module))

    assert {:file, _path} = :code.is_loaded(module)
  end

  test "drops malformed section nodes" do
    module = Module.concat(__MODULE__, "MalformedSections#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        @behaviour Spark.Dsl.Extension

        def add_extensions, do: []
        def sections, do: [:invalid]
        def dsl_patches, do: []
      end
      """)

    assert %{sections: []} =
             binary
             |> index(module, "malformed_sections.ex")
             |> metadata(Entry.integration_subject("spark", :extension, module))
  end

  test "times out callbacks without exiting the caller" do
    module = Module.concat(__MODULE__, "SlowCallback#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []
        def opt_schema, do: Process.sleep(:infinity)
      end
      """)

    assert [] = index(binary, module, "slow_callback.ex")
  end

  test "stops callback work when the indexing caller exits" do
    suffix = System.unique_integer([:positive])
    module = Module.concat(__MODULE__, "OwnedCallback#{suffix}")
    receiver = String.to_atom("spark_indexer_test_#{suffix}")
    Process.register(self(), receiver)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
        @spark_dsl true

        def default_extensions, do: []
        def default_extension_kinds, do: []
        def single_extension_kinds, do: []

        def opt_schema do
          send(Process.whereis(#{inspect(receiver)}), {:callback, self()})
          Process.sleep(:infinity)
        end
      end
      """)

    caller = spawn(fn -> index(binary, module, "owned_callback.ex") end)
    assert_receive {:callback, callback}
    monitor = Process.monitor(callback)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^callback, _reason}
  end

  test "indexes behaviour and Spark type relations with the skip decision" do
    suffix = System.unique_integer([:positive])
    behaviour = Module.concat(__MODULE__, "Behaviour#{suffix}")
    type = Module.concat(__MODULE__, "Type#{suffix}")
    included = Module.concat(__MODULE__, "Included#{suffix}")
    skipped = Module.concat(__MODULE__, "Skipped#{suffix}")

    modules = [behaviour, included, skipped]

    on_exit(fn ->
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)

    binaries =
      """
      defmodule #{inspect(behaviour)} do
        @callback run() :: term()
      end

      defmodule #{inspect(included)} do
        @behaviour #{inspect(behaviour)}
        Module.register_attribute(__MODULE__, :spark_is, persist: true)
        @spark_is #{inspect(type)}
        def run, do: :ok
        def constraints, do: [max_length: [type: :non_neg_integer]]
        def skip_in_spark_autocomplete, do: false
      end

      defmodule #{inspect(skipped)} do
        @behaviour #{inspect(behaviour)}
        def run, do: :ok
        def skip_in_spark_autocomplete, do: true
      end
      """
      |> Code.compile_string()
      |> Map.new()

    included_entries = index(Map.fetch!(binaries, included), included, "included.ex")
    skipped_entries = index(Map.fetch!(binaries, skipped), skipped, "skipped.ex")

    included_relation =
      Entry.integration_subject(
        "spark",
        :behaviour,
        "#{Atom.to_string(behaviour)}/#{Atom.to_string(included)}"
      )

    skipped_relation =
      Entry.integration_subject(
        "spark",
        :behaviour,
        "#{Atom.to_string(behaviour)}/#{Atom.to_string(skipped)}"
      )

    type_relation =
      Entry.integration_subject(
        "spark",
        :type,
        "#{Atom.to_string(type)}/#{Atom.to_string(included)}"
      )

    assert %{module: module, skip?: false, constraints: [%{name: "max_length"}]} =
             metadata(included_entries, included_relation)

    assert module == Atom.to_string(included)
    assert %{module: module, skip?: true} = metadata(skipped_entries, skipped_relation)
    assert module == Atom.to_string(skipped)
    assert %{module: module} = metadata(included_entries, type_relation)
    assert module == Atom.to_string(included)
  end

  test "indexes EEP-48 function option schemas for callable arities" do
    module = Module.concat(__MODULE__, "Functions#{System.unique_integer([:positive])}")
    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true)

    on_exit(fn ->
      Code.compiler_options(compiler_options)
      :code.purge(module)
      :code.delete(module)
    end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        @doc "Creates a value"
        @doc spark_opts: [{1, [upsert?: [type: :boolean, default: false]]}]
        def create(value, params \\\\ %{}, opts \\\\ []), do: {value, params, opts}
      end
      """)

    entries = index(binary, module, "functions.ex")
    function = &Entry.integration_subject("spark", :function, &1)

    assert [%{name: "upsert?", type: %{kind: :boolean}}] =
             metadata(entries, function.("#{Forge.Formats.mfa(module, :create, 2)}/1"))
  end

  defp index(binary, module, source_path) do
    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])
    Integrations.index_beam(binary, %{module: module, attributes: attributes}, source_path)
  end

  defp dsl_source(module, value) do
    """
    defmodule #{inspect(module)} do
      Module.register_attribute(__MODULE__, :spark_dsl, persist: true)
      @spark_dsl true

      def default_extensions, do: []
      def default_extension_kinds, do: []
      def single_extension_kinds, do: []
      def opt_schema, do: [source: [type: {:literal, #{inspect(value)}}]]
    end
    """
  end

  defp metadata(entries, subject) do
    assert %Entry{metadata: %{payload: payload}} = Enum.find(entries, &(&1.subject == subject))
    payload
  end
end
