defmodule Expert.Search.Indexer.SourceTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Search.Indexer
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Source
  alias Forge.Ast
  alias Forge.Document

  setup do
    project = project()
    start_supervised!({Expert.Project.Store, []})
    Expert.Project.Store.set_projects([project])
    Expert.Project.Store.transition(project, :ready)
    start_supervised!({ModuleRegistry, project})
    patch(EngineApi, :analyze, fn ^project, document, opts -> Ast.analyze(document, opts) end)
    {:ok, project: project}
  end

  test "analyzes source in the Engine runtime", %{project: project} do
    test_pid = self()

    patch(EngineApi, :analyze, fn ^project, document, opts ->
      send(test_pid, {:analyze, opts})
      Ast.analyze(document, opts)
    end)

    assert {:ok, _entries} = Source.index("example.ex", "1", [], project)
    assert_received {:analyze, [expand_uses: true]}
  end

  @tag :tmp_dir
  test "resolves imported calls a build traced, without compiling again", %{
    project: project,
    tmp_dir: tmp_dir
  } do
    patch(EngineApi, :analyze, fn ^project, document, _opts -> Ast.analyze(document) end)
    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)
    patch(EngineApi, :module_exports, fn ^project, module -> Engine.Modules.exports(module) end)
    patch(Engine, :broadcast, :ok)
    start_supervised!({Engine.Compilation.Tracer, nil})

    source = """
    defmodule SourceTest.Helpers do
      def helper(value), do: value
      defmacro helper_macro(value), do: value
    end

    defmodule SourceTest.Using do
      defmacro __using__(_), do: quote(do: import(SourceTest.Helpers))
    end

    defmodule SourceTest.User do
      use SourceTest.Using

      def run(value) do
        helper(value)
        helper_macro(value)
      end
    end
    """

    source_path = Path.join(tmp_dir, "lib/user.ex")
    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, source)

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule SourceTest.MixProject do
      use Mix.Project
      def project, do: [app: :source_test, version: "0.1.0"]
    end
    """)

    compiler_options = Code.compiler_options()
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    Code.compiler_options(
      tracers: [Engine.Compilation.Tracer],
      parser_options: [columns: true],
      debug_info: true
    )

    build_path = Path.join(tmp_dir, "_build")

    ebin =
      Mix.Project.in_project(:source_test, tmp_dir, [build_path: build_path], fn _ ->
        compile_path = Mix.Project.compile_path()
        File.mkdir_p!(compile_path)

        {:ok, _modules, _diagnostics} =
          Kernel.ParallelCompiler.compile_to_path([source_path], compile_path,
            return_diagnostics: true
          )

        compile_path
      end)

    register_beams = fn ->
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Beams.stream(project: project)
      |> Stream.run()
    end

    references = fn ->
      assert {:ok, entries} = Source.index(source_path, source, nil, project)

      for entry <- entries,
          entry.subtype == :reference,
          do: {entry.range.start.line, entry.subject}
    end

    register_beams.()
    assert {14, Forge.Formats.mfa(SourceTest.Helpers, :helper, 1)} in references.()
    assert {15, Forge.Formats.mfa(SourceTest.Helpers, :helper_macro, 1)} in references.()

    assert :ok = ModuleRegistry.clear(project)
    register_beams.()
    assert {14, Forge.Formats.mfa(SourceTest.Helpers, :helper, 1)} in references.()
  end

  @tag :tmp_dir
  test "uses a build's imported calls only for the file they were traced from", %{
    project: project,
    tmp_dir: tmp_dir
  } do
    patch_engine_lookups(project)
    document = caller_document(tmp_dir, "lib/caller.ex")
    register_traced_caller(project, tmp_dir, document.path)

    assert {:ok, entries} = Source.index_document(document, nil, project)
    assert {3, Forge.Formats.mfa(SourceTest.Helpers, :helper, 1)} in references(entries)

    other = caller_document(tmp_dir, "lib/other.ex")
    assert {:ok, entries} = Source.index_document(other, nil, project)
    assert {3, Forge.Formats.mfa(SourceTest.Caller, :helper, 1)} in references(entries)
  end

  @tag :tmp_dir
  test "indexes a document with the imported calls that came with it, never the beam's", %{
    project: project,
    tmp_dir: tmp_dir
  } do
    patch_engine_lookups(project)
    document = caller_document(tmp_dir, "lib/caller.ex")
    register_traced_caller(project, tmp_dir, document.path)
    path = document.path

    assert {:ok, ^path, entries} = Indexer.document(project, document, [])
    assert {3, Forge.Formats.mfa(SourceTest.Caller, :helper, 1)} in references(entries)

    traced = [{SourceTest.Caller, [{3, 5, "Elixir.SourceTest.Other", "helper", 1}]}]
    assert {:ok, ^path, entries} = Indexer.document(project, document, traced)
    assert {3, Forge.Formats.mfa(SourceTest.Other, :helper, 1)} in references(entries)
  end

  defp patch_engine_lookups(project) do
    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)
    patch(EngineApi, :module_exports, fn ^project, module -> Engine.Modules.exports(module) end)
  end

  defp caller_document(tmp_dir, relative_path) do
    source = """
    defmodule SourceTest.Caller do
      def run(value) do
        helper(value)
      end
    end
    """

    Document.new(Path.join(tmp_dir, relative_path), source, 1)
  end

  # a build of the caller that resolved its line 3 call through an import
  defp register_traced_caller(project, tmp_dir, path) do
    calls = [{3, 5, "Elixir.SourceTest.Helpers", "helper", 1}]

    File.write!(
      Path.join(tmp_dir, "Elixir.SourceTest.Caller.imported_calls"),
      :erlang.term_to_binary({path, calls})
    )

    beam_path = Path.join(tmp_dir, "Elixir.SourceTest.Caller.beam")
    ModuleRegistry.put(project, SourceTest.Caller, beam_path, :example, run: 1)
  end

  defp references(entries) do
    for entry <- entries, entry.subtype == :reference, do: {entry.range.start.line, entry.subject}
  end

  test "caches Engine lookups in the module registry", %{project: project} do
    test_pid = self()

    patch(EngineApi, :application, fn ^project, module ->
      send(test_pid, {:application, module})
      :example
    end)

    patch(EngineApi, :available_module?, fn ^project, _module -> false end)

    source = """
    defmodule Example do
      Example
    end
    """

    assert {:ok, entries} = Source.index("example.ex", source, nil, project)
    assert Enum.any?(entries, &(&1.application == :example))

    assert_received {:application, Example}
    refute_received {:application, Example}
  end

  test "resolves imported calls with registered Engine exports", %{project: project} do
    test_pid = self()

    patch(EngineApi, :module_exports, fn ^project, module ->
      send(test_pid, {:module_exports, module})

      case module do
        Imported -> {:ok, %{functions: [called: 0], macros: []}}
        module -> Engine.Modules.exports(module)
      end
    end)

    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)

    source = """
    defmodule Example do
      import Imported

      def run do
        called()
        called()
      end
    end
    """

    assert {:ok, entries} = Source.index("example.ex", source, nil, project)

    subject = Forge.Formats.mfa(Imported, :called, 0)
    assert 2 = Enum.count(entries, &(&1.subject == subject and &1.subtype == :reference))
    assert_received {:module_exports, Imported}
    refute_received {:module_exports, Imported}
  end

  test "does not cache transient module export errors", %{project: project} do
    {:ok, response} = Agent.start_link(fn -> :error end)

    patch(EngineApi, :module_exports, fn ^project, module ->
      case module do
        Imported ->
          case Agent.get(response, & &1) do
            :error -> :error
            :ok -> {:ok, %{functions: [other: 0], macros: []}}
          end

        module ->
          Engine.Modules.exports(module)
      end
    end)

    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)

    source = """
    defmodule Example do
      import Imported

      def run, do: missing()
    end
    """

    assert {:ok, first_entries} = Source.index("example.ex", source, nil, project)
    assert Enum.any?(first_entries, &(&1.subject == Forge.Formats.mfa(Imported, :missing, 0)))

    Agent.update(response, fn :error -> :ok end)

    assert {:ok, second_entries} = Source.index("example.ex", source, nil, project)
    refute Enum.any?(second_entries, &(&1.subject == Forge.Formats.mfa(Imported, :missing, 0)))
    assert Enum.any?(second_entries, &(&1.subject == Forge.Formats.mfa(Example, :missing, 0)))
  end
end
