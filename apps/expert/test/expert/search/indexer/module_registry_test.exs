defmodule Expert.Search.Indexer.ModuleRegistryTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.ModuleRegistry

  setup do
    start_supervised!({Expert.Project.Store, []})
    patch(Expert.Progress, :begin, fn _title, _opts -> {:error, :rejected} end)
    :ok
  end

  @tag :tmp_dir
  test "registers a module while reading each BEAM once", %{tmp_dir: tmp_dir} do
    module = Module.concat(__MODULE__, "RegistryModule#{System.unique_integer([:positive])}")
    source_path = Path.join(tmp_dir, "registry_module.ex")
    beam_dir = Path.join(tmp_dir, "ebin")

    File.mkdir_p!(beam_dir)

    File.write!(source_path, """
    defmodule #{inspect(module)} do
      def public_function, do: :ok
      defmacro public_macro, do: :ok
    end
    """)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: false)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    assert {:ok, [^module], %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path([source_path], beam_dir,
               return_diagnostics: true
             )

    :code.purge(module)
    :code.delete(module)
    beam_path = Path.join(beam_dir, Atom.to_string(module) <> ".beam")
    spy(File)

    project = project()
    start_supervised!({ModuleRegistry, project})

    [beam_path]
    |> Beams.stream(project: project, applications: %{beam_dir => :registry_app})
    |> Enum.to_list()

    beam_reads = Enum.filter(history(File), &match?({:read, [^beam_path]}, &1))
    assert [{:read, [^beam_path]}] = beam_reads
    assert ModuleRegistry.available_module?(project, module)
    assert ModuleRegistry.application(project, module) == :registry_app
    assert ModuleRegistry.beam_path(project, module) == Forge.Path.native(beam_path)
    assert {:ok, exports} = ModuleRegistry.module_exports(project, module)
    assert {:public_function, 0} in exports.functions
    assert {:public_macro, 0} in exports.macros
    refute Code.loaded?(module)
  end

  @tag :tmp_dir
  test "registers the imported functions a module calls", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    imported = Module.concat(__MODULE__, "Imported#{suffix}")
    module = Module.concat(__MODULE__, "Importing#{suffix}")
    source_path = Path.join(tmp_dir, "importing.ex")
    beam_dir = Path.join(tmp_dir, "ebin")

    File.mkdir_p!(beam_dir)

    File.write!(source_path, """
    defmodule #{inspect(imported)} do
      def helper(value), do: value
    end

    defmodule #{inspect(module)} do
      import #{inspect(imported)}

      def run(value) do
        helper(value)
        #{inspect(imported)}.helper(value)
      end
    end
    """)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: true, parser_options: [columns: true])
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    assert {:ok, _modules, _diagnostics} =
             Kernel.ParallelCompiler.compile_to_path([source_path], beam_dir,
               return_diagnostics: true
             )

    project = project()
    start_supervised!({ModuleRegistry, project})

    beam_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Beams.stream(project: project)
    |> Enum.to_list()

    remote_column = String.length("    #{inspect(imported)}.") + 1

    assert {:ok, {^imported, :helper, 1}} = ModuleRegistry.imported_call(project, module, {9, 5})
    assert :error = ModuleRegistry.imported_call(project, module, {10, remote_column})
  end

  test "clears metadata without replacing the registry table" do
    project = project()
    start_supervised!({ModuleRegistry, project})
    registry = ModuleRegistry.name(project)
    table = :ets.whereis(registry)
    ModuleRegistry.put(project, Example, "/example.beam", :example, run: 0)

    assert :ok = ModuleRegistry.clear(project)

    assert :ets.whereis(registry) == table
    refute ModuleRegistry.available_module?(project, Example)
    refute ModuleRegistry.available_module?(project, Kernel)
  end

  test "uses project runtime exports for implicit imports" do
    project = project()
    Expert.Project.Store.set_projects([project])
    Expert.Project.Store.transition(project, :ready)
    start_supervised!({ModuleRegistry, project})

    exports = %{functions: [project_runtime: 0], macros: []}
    patch(Expert.EngineApi, :module_exports, fn ^project, Kernel -> {:ok, exports} end)

    assert {:ok, ^exports} = ModuleRegistry.module_exports(project, Kernel)
  end

  test "looks up missing metadata after the project becomes ready" do
    project = project()
    Expert.Project.Store.set_projects([project])
    start_supervised!({ModuleRegistry, project})
    test_pid = self()

    patch(Expert.EngineApi, :module_exports, fn ^project, Example ->
      send(test_pid, :engine_lookup)
      {:ok, %{functions: [run: 0], macros: []}}
    end)

    assert :error = ModuleRegistry.module_exports(project, Example)
    refute_received :engine_lookup

    Expert.Project.Store.transition(project, :ready)
    assert {:ok, %{functions: [run: 0]}} = ModuleRegistry.module_exports(project, Example)
    assert_received :engine_lookup

    assert {:ok, %{functions: [run: 0]}} = ModuleRegistry.module_exports(project, Example)
    refute_received :engine_lookup

    ModuleRegistry.prune(project, [])
    assert {:ok, _} = ModuleRegistry.module_exports(project, Example)
    assert_received :engine_lookup
  end

  test "prunes deleted modules and cached Engine lookups" do
    project = project()
    start_supervised!({ModuleRegistry, project})
    registry = ModuleRegistry.name(project)
    ModuleRegistry.put(project, Current, "/current.beam", :example, run: 0)
    ModuleRegistry.put(project, Removed, "/removed.beam", :example, run: 0)

    :ets.insert(registry, [
      {{:available_module, Current}, true},
      {{:available_module, Removed}, true}
    ])

    assert :ok = ModuleRegistry.prune(project, [Forge.Path.native("/current.beam")])

    assert ModuleRegistry.available_module?(project, Current)
    refute ModuleRegistry.available_module?(project, Removed)
    assert [] = :ets.lookup(registry, {:available_module, Current})
    assert [] = :ets.lookup(registry, {:available_module, Removed})
  end
end
