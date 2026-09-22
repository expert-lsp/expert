defmodule Expert.Search.Indexer.BeamsTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.RangeSupport

  alias Expert.Search.Indexer.Beams
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  @moduletag :tmp_dir

  setup do
    patch(Expert.Progress, :begin, fn _title, _opts ->
      {:ok, System.unique_integer([:positive])}
    end)

    patch(Expert.Progress, :report, :ok)
    patch(Expert.Progress, :complete, :ok)

    :ok
  end

  describe "stream/1" do
    test "uses native source paths from BEAM metadata", %{tmp_dir: tmp_dir} do
      module = unique_module("NativeSourcePath")

      %{
        entries: entries,
        manifest_entries: manifest_entries,
        source_path: source_path
      } =
        index_source!(
          tmp_dir,
          "defmodule #{inspect(module)}, do: nil",
          expected_modules: [module],
          rewrite_source?: false
        )

      source_path = Forge.Path.native(source_path)

      assert Enum.all?(entries, &(&1.path == source_path))
      assert [%{output_path: ^source_path, source_path: ^source_path}] = manifest_entries
    end

    test "indexes public functions and macros from beam metadata", %{tmp_dir: tmp_dir} do
      module = unique_module("Definitions")
      public_fun = Formats.mfa(module, :public_fun, 0)
      with_default_0 = Formats.mfa(module, :with_default, 0)
      with_default_1 = Formats.mfa(module, :with_default, 1)
      with_default_2 = Formats.mfa(module, :with_default, 2)
      guarded_0 = Formats.mfa(module, :guarded, 0)
      guarded_1 = Formats.mfa(module, :guarded, 1)
      public_macro = Formats.mfa(module, :public_macro, 1)

      source = """
      defmodule #{inspect(module)} do
        def public_fun, do: private_fun()
        def with_default(a \\\\ :ok, b \\\\ :ok), do: {a, b}
        def guarded(value \\\\ :ok) when is_atom(value), do: value
        defmacro public_macro(expr), do: expr
        defp private_fun, do: :ok
      end
      """

      %{entries: entries} =
        index_source!(
          tmp_dir,
          source,
          expected_modules: [module],
          rewrite_source?: false
        )

      assert Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
             )

      refute Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :struct and &1.subtype == :definition)
             )

      for {subject, type} <- [
            {public_fun, {:function, :public}},
            {with_default_0, {:function, :public}},
            {with_default_1, {:function, :public}},
            {with_default_2, {:function, :public}},
            {guarded_0, {:function, :public}},
            {guarded_1, {:function, :public}},
            {public_macro, {:macro, :public}}
          ] do
        assert Enum.any?(
                 entries,
                 &(&1.subject == subject and &1.type == type and &1.subtype == :definition)
               )
      end

      for subject <- [with_default_0, with_default_1, with_default_2, guarded_0, guarded_1] do
        assert [%Entry{}] =
                 Enum.filter(
                   entries,
                   &(&1.subject == subject and &1.type == {:function, :public} and
                       &1.subtype == :definition)
                 )
      end

      private_fun = Formats.mfa(module, :private_fun, 0)
      refute Enum.any?(entries, &(&1.subject == private_fun and &1.subtype == :definition))
    end

    test "indexes definitions from module binaries", %{
      tmp_dir: tmp_dir
    } do
      module = unique_module("BinaryDefinitions")

      %{beam_paths_by_module: beam_paths_by_module} =
        compile_source!(
          tmp_dir,
          """
          defmodule #{inspect(module)} do
            def public_fun, do: :ok
          end
          """,
          expected_modules: [module],
          rewrite_source?: false
        )

      {entries, _manifest_entries} = index_beams([Map.fetch!(beam_paths_by_module, module)])

      for {subject, type} <- [
            {module, :module},
            {Formats.mfa(module, :public_fun, 0), {:function, :public}}
          ] do
        assert Enum.any?(
                 entries,
                 &(&1.subject == subject and &1.type == type and &1.subtype == :definition)
               )
      end

      assert %Entry{range: %{start: start_pos}} =
               Enum.find(entries, &(&1.subject == Formats.mfa(module, :public_fun, 0)))

      assert start_pos.line == 2
      assert start_pos.valid?
      assert start_pos.document_line_count >= start_pos.line
      assert start_pos.context_line != nil
    end

    test "synthesizes contextual ranges for macro-generated definitions from beam metadata", %{
      tmp_dir: tmp_dir
    } do
      macro_module = unique_module("GeneratedFunctionMacro")
      target_module = unique_module("GeneratedFunctionTarget")

      source = """
      defmodule #{inspect(macro_module)} do
        defmacro fun(name) do
          quote do
            def unquote(name), do: :ok
          end
        end
      end

      defmodule #{inspect(target_module)} do
        require #{inspect(macro_module)}
        #{inspect(macro_module)}.fun(gen)
      end
      """

      %{beam_paths_by_module: beam_paths_by_module} =
        compile_source!(tmp_dir, source,
          expected_modules: [macro_module, target_module],
          rewrite_source?: false
        )

      {entries, _manifest_entries} =
        index_beams([Map.fetch!(beam_paths_by_module, target_module)])

      generated_fun = Formats.mfa(target_module, :gen, 0)

      macro_call_line =
        source |> String.split("\n") |> Enum.find_index(&String.contains?(&1, ".fun(gen)"))

      macro_call_line = macro_call_line + 1
      macro_call_text = source |> String.split("\n") |> Enum.at(macro_call_line - 1)
      {gen_byte, _length} = :binary.match(macro_call_text, "gen)")
      gen_column = macro_call_text |> binary_part(0, gen_byte) |> String.length() |> Kernel.+(1)

      assert %Entry{range: range} =
               Enum.find(
                 entries,
                 &(&1.subject == generated_fun and &1.type == {:function, :public} and
                     &1.subtype == :definition)
               )

      assert range.start.line == macro_call_line
      assert range.start.character == gen_column
      assert range.end.line == macro_call_line
      assert range.end.character == gen_column + String.length("gen")
      assert range.start.valid?
      assert range.start.document_line_count == range.start.line
      assert range.start.context_line != nil
    end

    test "does not run the source indexer for BEAM-backed entries", %{tmp_dir: tmp_dir} do
      patch(Expert.Search.Indexer.Source, :index, fn _path, _source, _extractors ->
        flunk("BEAM indexing must not call the source indexer")
      end)

      module = unique_module("NoSourceIndexer")

      %{entries: entries} =
        index_source!(
          tmp_dir,
          "defmodule #{inspect(module)} do\n  def value, do: :ok\nend\n",
          expected_modules: [module],
          rewrite_source?: false
        )

      assert Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
             )
    end

    test "preserves defdelegate metadata without dangling block ids", %{tmp_dir: tmp_dir} do
      module = unique_module("Delegate")

      %{entries: entries, source_path: source_path} =
        index_source!(
          tmp_dir,
          """
          defmodule #{inspect(module)} do
            defdelegate trim(value), to: String
          end
          """,
          expected_modules: [module],
          rewrite_source?: false
        )

      trim_mfa = Formats.mfa(module, :trim, 1)

      assert %Entry{
               type: {:function, :delegate},
               block_id: :root,
               metadata: %{original_mfa: original_mfa}
             } =
               Enum.find(
                 entries,
                 &(&1.subject == trim_mfa and &1.type == {:function, :delegate} and
                     &1.subtype == :definition)
               )

      assert original_mfa == Formats.mfa(String, :trim, 1)

      refute Enum.any?(
               entries,
               &(&1.subject == trim_mfa and &1.type == {:function, :public} and
                   &1.subtype == :definition)
             )

      assert %Entry{subject: %{root: %{}}} =
               Enum.find(
                 entries,
                 &(&1.path == source_path and &1.type == :metadata and
                     &1.subtype == :block_structure)
               )
    end

    test "preserves all callable defdelegate arities from default arguments", %{tmp_dir: tmp_dir} do
      module = unique_module("DelegateDefaults")

      %{entries: entries} =
        index_source!(
          tmp_dir,
          """
          defmodule #{inspect(module)} do
            defdelegate trim(value \\\\ " default "), to: String
          end
          """,
          expected_modules: [module],
          rewrite_source?: false
        )

      for arity <- 0..1 do
        trim_mfa = Formats.mfa(module, :trim, arity)

        assert [
                 %Entry{
                   type: {:function, :delegate},
                   block_id: :root,
                   metadata: %{original_mfa: original_mfa}
                 }
               ] =
                 Enum.filter(
                   entries,
                   &(&1.subject == trim_mfa and &1.type == {:function, :delegate} and
                       &1.subtype == :definition)
                 )

        assert original_mfa == Formats.mfa(String, :trim, 1)

        refute Enum.any?(
                 entries,
                 &(&1.subject == trim_mfa and &1.type == {:function, :public} and
                     &1.subtype == :definition)
               )
      end
    end

    test "does not import delegates for modules whose beams were not indexed", %{tmp_dir: tmp_dir} do
      indexed_module = unique_module("IndexedDelegate")
      skipped_module = unique_module("SkippedDelegate")

      %{beam_paths_by_module: beam_paths_by_module} =
        compile_source!(
          tmp_dir,
          """
          defmodule #{inspect(indexed_module)} do
            defdelegate trim(value), to: String
          end

          defmodule #{inspect(skipped_module)} do
            defdelegate downcase(value), to: String
          end
          """,
          expected_modules: [indexed_module, skipped_module],
          rewrite_source?: false
        )

      {entries, _manifest_entries} =
        index_beams([Map.fetch!(beam_paths_by_module, indexed_module)])

      indexed_trim = Formats.mfa(indexed_module, :trim, 1)
      skipped_downcase = Formats.mfa(skipped_module, :downcase, 1)

      assert Enum.any?(
               entries,
               &(&1.subject == indexed_trim and &1.type == {:function, :delegate} and
                   &1.subtype == :definition)
             )

      refute Enum.any?(entries, &(&1.subject == skipped_module and &1.subtype == :definition))

      refute Enum.any?(
               entries,
               &(&1.subject == skipped_downcase and &1.type == {:function, :delegate} and
                   &1.subtype == :definition)
             )
    end

    test "does not import nested module delegates when only parent beam was indexed", %{
      tmp_dir: tmp_dir
    } do
      parent_module = unique_module("ParentDelegate")
      child_module = Module.concat(parent_module, Child)

      %{beam_paths_by_module: beam_paths_by_module} =
        compile_source!(
          tmp_dir,
          """
          defmodule #{inspect(parent_module)} do
            def value, do: :ok

            defmodule Child do
              defdelegate downcase(value), to: String
            end
          end
          """,
          expected_modules: [parent_module, child_module],
          rewrite_source?: false
        )

      {entries, _manifest_entries} =
        index_beams([Map.fetch!(beam_paths_by_module, parent_module)])

      child_downcase = Formats.mfa(child_module, :downcase, 1)

      assert Enum.any?(
               entries,
               &(&1.subject == parent_module and &1.type == :module and &1.subtype == :definition)
             )

      refute Enum.any?(entries, &(&1.subject == child_module and &1.subtype == :definition))

      refute Enum.any?(
               entries,
               &(&1.subject == child_downcase and &1.type == {:function, :delegate} and
                   &1.subtype == :definition)
             )
    end

    test "reports progress per beam chunk instead of per beam", %{tmp_dir: tmp_dir} do
      test_pid = self()

      patch(Expert.Progress, :report, fn _token, opts ->
        send(test_pid, {:dependency_progress_report, opts})
        :ok
      end)

      modules = for index <- 1..4, do: unique_module("Progress#{index}")

      source =
        Enum.map_join(modules, "\n", fn module ->
          """
          defmodule #{inspect(module)} do
            def value, do: :ok
          end
          """
        end)

      %{beam_paths: beam_paths} =
        compile_source!(tmp_dir, source,
          expected_modules: modules,
          rewrite_source?: false
        )

      assert [_first, _second | _rest] = beam_paths

      {entries, _manifest_entries} = index_beams(beam_paths)

      for module <- modules do
        assert Enum.any?(
                 entries,
                 &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
               )
      end

      assert_receive {:dependency_progress_report, _opts}
      refute_receive {:dependency_progress_report, _opts}, 100
    end

    test "indexes struct definitions from beam metadata", %{tmp_dir: tmp_dir} do
      module = unique_module("Struct")

      source = """
      defmodule #{inspect(module)} do
        defstruct [:name]
      end
      """

      %{entries: entries} =
        index_source!(
          tmp_dir,
          source,
          expected_modules: [module],
          rewrite_source?: false
        )

      assert Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :struct and &1.subtype == :definition)
             )
    end

    test "indexes protocols and implementations from beam metadata", %{tmp_dir: tmp_dir} do
      protocol = unique_module("Protocol")
      implementation = Module.concat(protocol, Atom)

      source = """
      defprotocol #{inspect(protocol)} do
        def to_value(value)
      end

      defimpl #{inspect(protocol)}, for: Atom do
        def to_value(value), do: Atom.to_string(value)
      end
      """

      %{entries: entries} =
        index_source!(
          tmp_dir,
          source,
          expected_modules: [protocol, implementation],
          rewrite_source?: false
        )

      protocol_fun = Formats.mfa(protocol, :to_value, 1)

      for {subject, type} <- [
            {protocol, {:protocol, :definition}},
            {protocol_fun, {:function, :public}},
            {protocol, {:protocol, :implementation}},
            {implementation, :module}
          ] do
        assert Enum.any?(
                 entries,
                 &(&1.subject == subject and &1.type == type and &1.subtype == :definition)
               )
      end

      assert %Entry{range: range} =
               Enum.find(
                 entries,
                 &(&1.subject == protocol and &1.type == {:protocol, :definition} and
                     &1.subtype == :definition)
               )

      assert extract(source, range) == inspect(protocol)

      for {subject, type} <- [
            {protocol, {:protocol, :implementation}},
            {implementation, :module}
          ] do
        assert %Entry{range: range} =
                 Enum.find(
                   entries,
                   &(&1.subject == subject and &1.type == type and &1.subtype == :definition)
                 )

        assert extract(source, range) == "defimpl #{inspect(protocol)}, for: Atom do"
      end
    end

    test "uses source spans for module definition ranges", %{tmp_dir: tmp_dir} do
      module = unique_module("Range")

      %{entries: entries} =
        index_source!(
          tmp_dir,
          "defmodule #{inspect(module)} do\nend\n",
          expected_modules: [module],
          rewrite_source?: false
        )

      assert %Entry{range: range} =
               Enum.find(
                 entries,
                 &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
               )

      assert range.start.line == 1
      assert range.start.character == 11
      assert range.end.character == 11 + String.length(Formats.module(module))
    end

    test "uses source-visible ranges for nested module definitions", %{tmp_dir: tmp_dir} do
      parent = unique_module("NestedRange")
      child = Module.concat(parent, Child)
      sibling = Module.concat(parent, Sibling)

      source = """
      defmodule #{inspect(parent)} do
        defmodule Child do
        end

        defmodule __MODULE__.Sibling do
        end
      end
      """

      %{entries: entries} =
        index_source!(tmp_dir, source,
          expected_modules: [parent, child, sibling],
          rewrite_source?: false
        )

      assert %Entry{range: range} =
               Enum.find(
                 entries,
                 &(&1.subject == child and &1.type == :module and &1.subtype == :definition)
               )

      assert extract(source, range) == "Child"

      assert %Entry{range: range} =
               Enum.find(
                 entries,
                 &(&1.subject == sibling and &1.type == :module and &1.subtype == :definition)
               )

      assert extract(source, range) == "__MODULE__.Sibling"
    end
  end

  defp index_source!(tmp_dir, source, opts) do
    context = compile_source!(tmp_dir, source, opts)
    {entries, manifest_entries} = index_beams(context.beam_paths)

    context
    |> Map.put(:entries, entries)
    |> Map.put(:manifest_entries, manifest_entries)
  end

  defp index_beams(paths) do
    paths
    |> Beams.stream()
    |> Enum.reduce({[], []}, fn
      {nil, manifest_entries}, {entries, manifests} ->
        {entries, [manifest_entries | manifests]}

      {entry, manifest_entries}, {entries, manifests} ->
        {[entry | entries], [manifest_entries | manifests]}
    end)
    |> then(fn {entries, manifests} ->
      {Enum.reverse(entries), manifests |> Enum.reverse() |> List.flatten()}
    end)
  end

  defp compile_source!(tmp_dir, source, opts) do
    source_path =
      [tmp_dir, "lib", "beam_source_#{System.unique_integer([:positive])}.ex"]
      |> Path.join()
      |> Forge.Path.native()

    ebin_path =
      Path.join([tmp_dir, "ebin", Integer.to_string(System.unique_integer([:positive]))])

    File.mkdir_p!(Path.dirname(source_path))
    File.mkdir_p!(ebin_path)
    File.write!(source_path, source)

    compiler_options = Code.compiler_options()

    compiled_modules =
      try do
        Code.compiler_options(debug_info: Keyword.get(opts, :debug_info?, true))

        assert {:ok, compiled_modules, %{compile_warnings: [], runtime_warnings: []}} =
                 Kernel.ParallelCompiler.compile_to_path([source_path], ebin_path,
                   return_diagnostics: true
                 )

        compiled_modules
      after
        Code.compiler_options(compiler_options)
      end

    case Keyword.fetch(opts, :expected_modules) do
      {:ok, expected_modules} ->
        assert Enum.sort(compiled_modules) == Enum.sort(expected_modules)

      :error ->
        :ok
    end

    if Keyword.get(opts, :rewrite_source?, true) do
      File.write!(source_path, "defmodule")
      File.touch!(source_path, {{2000, 1, 1}, {0, 0, 0}})
    end

    beam_paths_by_module =
      Map.new(compiled_modules, fn module ->
        {module, Path.join(ebin_path, Atom.to_string(module) <> ".beam")}
      end)

    %{
      beam_paths: Map.values(beam_paths_by_module),
      beam_paths_by_module: beam_paths_by_module,
      compiled_modules: compiled_modules,
      ebin_path: ebin_path,
      source_path: source_path
    }
  end

  defp unique_module(prefix) do
    Module.concat(__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}")
  end
end
