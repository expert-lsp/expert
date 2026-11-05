defmodule Expert.Integrations.CacheTest do
  use ExUnit.Case, async: true

  import Forge.Test.Fixtures

  alias Expert.Integrations.Cache

  setup do
    project = project()
    start_supervised!({Cache, project})
    %{project: project}
  end

  test "caches values by namespace", %{project: project} do
    assert :first = Cache.fetch(project, First, :key, fn -> :first end)
    assert :first = Cache.fetch(project, First, :key, fn -> :missing end)
    assert :second = Cache.fetch(project, Second, :key, fn -> :second end)
  end

  test "does not cache errors", %{project: project} do
    assert :error = Cache.fetch(project, __MODULE__, :key, fn -> :error end)
    assert :value = Cache.fetch(project, __MODULE__, :key, fn -> :value end)
  end

  test "clears cached values", %{project: project} do
    assert :old = Cache.fetch(project, __MODULE__, :key, fn -> :old end)
    assert :ok = Cache.clear(project)
    assert :new = Cache.fetch(project, __MODULE__, :key, fn -> :new end)
  end
end
