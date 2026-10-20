defmodule Expert.Search.Indexer.SourceTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Source
  alias Forge.Ast

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

  test "resolves imported calls from compiled modules", %{project: project} do
    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)
    patch(EngineApi, :module_exports, fn ^project, _module -> :error end)

    ModuleRegistry.put(project, Example, "/example.beam", :example, [run: 0], %{
      {:called, 0} => Imported
    })

    source = """
    defmodule Example do
      def run, do: called()
    end
    """

    assert {:ok, entries} = Source.index("example.ex", source, nil, project)
    subject = Forge.Formats.mfa(Imported, :called, 0)
    assert Enum.any?(entries, &(&1.subject == subject and &1.subtype == :reference))
  end

  test "resolves calls to Kernel names to Kernel", %{project: project} do
    patch(EngineApi, :application, fn ^project, _module -> :example end)
    patch(EngineApi, :available_module?, fn ^project, _module -> false end)
    patch(EngineApi, :module_exports, fn ^project, _module -> :error end)

    ModuleRegistry.put(project, Kernel, "/kernel.beam", :elixir, "MACRO-to_string": 2)

    ModuleRegistry.put(project, Example, "/example.beam", :example, [run: 1], %{
      {:to_string, 1} => String.Chars
    })

    source = """
    defmodule Example do
      def run(value), do: to_string(value)
    end
    """

    assert {:ok, entries} = Source.index("example.ex", source, nil, project)
    subjects = for entry <- entries, entry.subtype == :reference, do: entry.subject
    assert Forge.Formats.mfa(Kernel, :to_string, 1) in subjects
    refute Forge.Formats.mfa(String.Chars, :to_string, 1) in subjects
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
