defmodule Expert.Search.Indexer.ModuleRegistryTest do
  use ExUnit.Case
  use Patch

  alias Expert.Search
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store.Backends.Sqlite

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    project = tmp_dir |> Forge.Document.Path.to_uri() |> Forge.Project.new()
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({Sqlite, [project, runtime_versions: %{erlang: "test", elixir: "test"}]})
    start_supervised!({Search.Store, [project, Sqlite]})
    patch(Expert.Progress, :begin, fn _title, _opts -> {:error, :rejected} end)
    {:ok, project: project}
  end

  test "registers a module while reading each BEAM once", %{project: project, tmp_dir: tmp_dir} do
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
    assert {"public_function", 0} in exports.functions
    assert {"public_macro", 0} in exports.macros
    refute Code.loaded?(module)
  end

  test "clears metadata without replacing the registry table", %{project: project} do
    start_supervised!({ModuleRegistry, project})
    registry = ModuleRegistry.name(project)
    table = :ets.whereis(registry)
    ModuleRegistry.put(project, "Elixir.Example", "/example.beam", :example, [{"run", 0}])

    assert :ok = ModuleRegistry.clear(project)

    assert :ets.whereis(registry) == table
    refute ModuleRegistry.available_module?(project, Example)
    refute ModuleRegistry.available_module?(project, Kernel)
  end

  test "loads stored modules without creating their atoms", %{project: project} do
    unique = System.unique_integer([:positive])
    module = "Elixir.Unloaded#{unique}"
    function = "unloaded_fun#{unique}"
    beam_path = Forge.Path.native("/ebin/#{module}.beam")
    stored = {beam_path, module, nil, %{functions: [{function, 0}], macros: []}}

    assert :ok = Search.Store.replace_modules(project, [stored])

    start_supervised!({ModuleRegistry, project})

    assert :ok = ModuleRegistry.persist(project)
    assert Search.Store.modules(project) == [stored]
    assert_raise ArgumentError, fn -> String.to_existing_atom(module) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(function) end
  end

  test "answers lookups from stored modules", %{project: project} do
    beam_path = Forge.Path.native("/ebin/Elixir.Stored.beam")
    stored = {beam_path, "Elixir.Stored", :stored, %{functions: [{"run", 0}], macros: []}}

    assert :ok = Search.Store.replace_modules(project, [stored])

    start_supervised!({ModuleRegistry, project})

    assert ModuleRegistry.application(project, Stored) == :stored
    assert ModuleRegistry.beam_path(project, Stored) == beam_path

    assert {:ok, %{functions: [{"run", 0}], macros: []}} =
             ModuleRegistry.module_exports(project, Stored)
  end

  test "persists registered modules", %{project: project} do
    start_supervised!({ModuleRegistry, project})
    ModuleRegistry.put(project, "Elixir.First", "/first.beam", :app, [{"run", 0}])
    ModuleRegistry.put(project, "Elixir.Second", "/second.beam", nil, [{"MACRO-run", 2}])

    first =
      {Forge.Path.native("/first.beam"), "Elixir.First", :app,
       %{functions: [{"run", 0}], macros: []}}

    second =
      {Forge.Path.native("/second.beam"), "Elixir.Second", nil,
       %{functions: [], macros: [{"run", 1}]}}

    assert :ok = ModuleRegistry.persist(project)
    assert Enum.sort(Search.Store.modules(project)) == Enum.sort([first, second])

    ModuleRegistry.put(project, "Elixir.First", "/first.beam", :app, [{"run", 1}])
    assert :ok = ModuleRegistry.prune(project, ["/first.beam"])
    assert :ok = ModuleRegistry.persist(project, ["/first.beam"], ["/second.beam"])

    changed = put_elem(first, 3, %{functions: [{"run", 1}], macros: []})
    assert Search.Store.modules(project) == [changed]
  end

  test "uses project runtime exports for implicit imports", %{project: project} do
    Expert.Project.Store.set_projects([project])
    Expert.Project.Store.transition(project, :ready)
    start_supervised!({ModuleRegistry, project})

    stored = %{functions: [{"project_runtime", 0}], macros: []}
    patch(Expert.EngineApi, :module_exports, fn ^project, Kernel -> {:ok, stored} end)

    assert {:ok, %{functions: [{"project_runtime", 0}], macros: []}} =
             ModuleRegistry.module_exports(project, Kernel)
  end

  test "looks up missing metadata after the project becomes ready", %{project: project} do
    Expert.Project.Store.set_projects([project])
    start_supervised!({ModuleRegistry, project})
    test_pid = self()

    patch(Expert.EngineApi, :module_exports, fn ^project, Example ->
      send(test_pid, :engine_lookup)
      {:ok, %{functions: [{"run", 0}], macros: []}}
    end)

    assert :error = ModuleRegistry.module_exports(project, Example)
    refute_received :engine_lookup

    Expert.Project.Store.transition(project, :ready)
    assert {:ok, %{functions: [{"run", 0}]}} = ModuleRegistry.module_exports(project, Example)
    assert_received :engine_lookup

    assert {:ok, %{functions: [{"run", 0}]}} = ModuleRegistry.module_exports(project, Example)
    refute_received :engine_lookup

    ModuleRegistry.prune(project, [])
    assert {:ok, _} = ModuleRegistry.module_exports(project, Example)
    assert_received :engine_lookup
  end

  test "prunes deleted modules and cached Engine lookups", %{project: project} do
    start_supervised!({ModuleRegistry, project})
    registry = ModuleRegistry.name(project)
    ModuleRegistry.put(project, "Elixir.Current", "/current.beam", :example, [{"run", 0}])
    ModuleRegistry.put(project, "Elixir.Removed", "/removed.beam", :example, [{"run", 0}])

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

  test "registers multiple modules in batch with put_all/2", %{project: project} do
    start_supervised!({ModuleRegistry, project})

    assert :ok = ModuleRegistry.put_all(project, [])

    modules = [
      {"Elixir.ModA", "/a.beam", :app_a, [{"foo", 1}]},
      {"Elixir.ModB", "/b.beam", :app_b, [{"bar", 2}]}
    ]

    assert :ok = ModuleRegistry.put_all(project, modules)

    assert ModuleRegistry.available_module?(project, ModA)
    assert ModuleRegistry.application(project, ModA) == :app_a
    assert ModuleRegistry.beam_path(project, ModA) == Forge.Path.native("/a.beam")

    assert {:ok, %{functions: [{"foo", 1}], macros: []}} =
             ModuleRegistry.module_exports(project, ModA)

    assert ModuleRegistry.available_module?(project, ModB)
    assert ModuleRegistry.application(project, ModB) == :app_b
    assert ModuleRegistry.beam_path(project, ModB) == Forge.Path.native("/b.beam")

    assert {:ok, %{functions: [{"bar", 2}], macros: []}} =
             ModuleRegistry.module_exports(project, ModB)
  end
end
