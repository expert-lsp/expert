defmodule Expert.Integrations.Spark.CallbacksTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Integrations.Cache
  alias Expert.Integrations.Spark.Callbacks
  alias Expert.Search.Indexer.ModuleRegistry

  setup do
    project = project()
    start_supervised!({ModuleRegistry, project})
    start_supervised!({Cache, project})
    %{project: project}
  end

  test "does not cache BEAM callbacks", %{project: project} do
    test_pid = self()
    {module, beam} = callback_beam()

    patch(EngineApi, :call, fn ^project, ^module, :options, [] ->
      send(test_pid, :callback)
      [:value]
    end)

    assert {:ok, [:value]} = Callbacks.fetch(project, beam, module, :options)
    assert {:ok, [:value]} = Callbacks.fetch(project, beam, module, :options)
    assert_received :callback
    assert_received :callback
  end

  test "does not cache runtime callback failures", %{project: project} do
    test_pid = self()
    module = register_callback(project)

    patch(EngineApi, :call, fn ^project, ^module, :options, [] ->
      send(test_pid, :callback)
      raise "callback failed"
    end)

    assert_raise RuntimeError, "callback failed", fn ->
      Callbacks.fetch(project, nil, module, :options)
    end

    assert_raise RuntimeError, "callback failed", fn ->
      Callbacks.fetch(project, nil, module, :options)
    end

    assert_received :callback
    assert_received :callback
  end

  test "clearing the integration cache clears runtime callbacks", %{project: project} do
    test_pid = self()
    module = register_callback(project)

    patch(EngineApi, :call, fn ^project, ^module, :options, [] ->
      send(test_pid, :callback)
      [:value]
    end)

    assert {:ok, [:value]} = Callbacks.fetch(project, nil, module, :options)
    assert {:ok, [:value]} = Callbacks.fetch(project, nil, module, :options)
    assert_received :callback
    refute_received :callback

    assert :ok = Cache.clear(project)
    assert {:ok, [:value]} = Callbacks.fetch(project, nil, module, :options)
    assert_received :callback
  end

  test "resolves and caches Spark type aliases", %{project: project} do
    test_pid = self()

    ModuleRegistry.put(project, Example, "example.beam", nil, [{:short_names, 0}])

    patch(EngineApi, :call, fn ^project, Example, :short_names, [] ->
      send(test_pid, :short_names)
      [example: Example.Type]
    end)

    type = %{aliases: %{}, alias_module: Example, alias_function: :builtins}
    expected = %{"example" => "Elixir.Example.Type"}

    assert ^expected = Callbacks.aliases(project, type)
    assert ^expected = Callbacks.aliases(project, type)
    assert_received :short_names
    refute_received :short_names
  end

  defp callback_beam do
    module = Module.concat(__MODULE__, "Callback#{System.unique_integer([:positive])}")
    beam = compile_callback(module, :value)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {module, beam}
  end

  defp register_callback(project) do
    module = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    ModuleRegistry.put(project, module, "example.beam", nil, [{:options, 0}])
    module
  end

  defp compile_callback(module, value) do
    [{^module, beam}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        def options, do: #{inspect(value)}
      end
      """)

    beam
  end
end
