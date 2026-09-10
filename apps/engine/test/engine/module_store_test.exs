defmodule Engine.ModuleStoreTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages

  alias ElixirSense.Providers.Plugins.ModuleStore, as: ElixirSenseModuleStore
  alias Engine.Dispatch
  alias Engine.ModuleStore

  setup do
    test_pid = self()
    start_supervised!(Dispatch)

    # Progress reports go to the manager node over erpc; keep them local.
    patch(Dispatch, :erpc_call, fn
      Expert.Progress, :begin, [_title, _opts] -> {:ok, System.unique_integer([:positive])}
      Expert.Progress, :report, _args -> :ok
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)

    patch(ElixirSenseModuleStore, :build, fn ->
      send(test_pid, :module_store_built)
      :ok
    end)

    pid = start_supervised!(ModuleStore)
    {:ok, pid: pid}
  end

  test "rebuilds the module store when the project compiles, and stays up", %{pid: pid} do
    ref = Process.monitor(pid)
    Dispatch.broadcast(project_compiled(status: :success))

    assert_receive :module_store_built
    refute_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "survives many builds in quick succession", %{pid: pid} do
    # It used to exit :normal after each build. As a permanent child that meant
    # one restart per build, so the fourth build within five seconds exceeded
    # the supervisor's restart intensity and took the engine application down.
    for _ <- 1..10 do
      Dispatch.broadcast(project_compiled(status: :success))
      assert_receive :module_store_built
    end

    assert Process.alive?(pid)
    assert Dispatch.registered?(pid)
  end
end
