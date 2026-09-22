defmodule Expert.Search.StoreTest do
  use ExUnit.Case, async: false
  use Patch
  use Expert.Test.DispatchFake

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Expert.Search.Store.State
  alias Expert.Test.DispatchFake
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    DispatchFake.start()

    patch(Features, :can_use_compressed_ets_table?, fn ->
      raise "manager storage probed VM features"
    end)

    Sqlite.destroy_all(project)

    start_supervised!({Sqlite, [project, runtime_versions: runtime_versions()]})

    start_supervised!({Store, [project, Sqlite]})

    Store.enable(project)
    assert_eventually(Store.loaded?(project), 1500)

    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project}
  end

  test "replaces and queries entries", %{project: project} do
    entries = [definition(id: 1, subject: Foo.Bar), reference(id: 2, subject: Foo.Bar)]

    assert :ok = Store.replace(project, entries)

    assert {:ok, [entry]} = Store.exact(project, "Foo.Bar", subtype: :definition)
    assert entry.id == 1
  end

  test "inserts index chunks", %{project: project} do
    old_entry = definition(id: 1, subject: Old.Module, path: "/old.ex")
    new_entry = definition(id: 2, subject: New.Module, path: "/new.ex")

    assert :ok = Store.replace(project, [old_entry])
    assert :ok = Store.insert(project, [new_entry])

    assert {:ok, [^old_entry]} = Store.fuzzy(project, "Old", subtype: :definition)
    assert {:ok, [^new_entry]} = Store.fuzzy(project, "New", subtype: :definition)
  end

  test "updates replace entries for the same path", %{project: project} do
    path = "/path/to/file.ex"

    assert :ok = Store.replace(project, [definition(id: 1, subject: Old.Module, path: path)])
    assert :ok = Store.update(project, path, [definition(id: 2, subject: New.Module, path: path)])
    send(Process.whereis(Store.name(project)), :flush_updates)

    assert_eventually(
      {:ok, [entry]} =
        Store.fuzzy(project, "New", type: :module, subtype: :definition)
    )

    assert entry.id == 2
    assert {:ok, []} = Store.exact(project, Old.Module, subtype: :definition)
  end

  test "flush update errors do not crash the store", %{project: project} do
    store = Process.whereis(Store.name(project))
    test_pid = self()

    patch(State, :flush_buffered_updates, fn _state ->
      send(test_pid, :flush_attempted)
      {:error, :readonly}
    end)

    send(store, :flush_updates)

    assert_receive :flush_attempted
    assert Process.alive?(store)
  end

  test "path_to_ids returns newest indexed id per path", %{project: project} do
    Store.replace(project, [
      definition(id: 1, subject: One, path: "/one.ex"),
      definition(id: 3, subject: Two, path: "/one.ex"),
      definition(id: 2, subject: Three, path: "/two.ex")
    ])

    assert %{"/one.ex" => 3, "/two.ex" => 2} = Store.path_to_ids(project)
  end

  test "destroy resets loaded state instead of corrupting it", %{project: project} do
    assert :ok = Store.replace(project, [definition(id: 1, subject: Destroyed.Module)])
    assert :ok = Store.destroy(project)

    refute Store.loaded?(project)
    assert [] = Store.exact(project, Destroyed.Module, [])

    assert :ok = Store.enable(project)
    assert {:ok, []} = Store.exact(project, Destroyed.Module, [])
  end

  test "writes the persisted index under the supplied engine runtime versions", %{
    project: project
  } do
    assert :ok = Store.replace(project, [definition(id: 1, subject: Engine.Runtime.Versioned)])

    assert File.exists?(Sqlite.database_path(project, runtime_versions()))
  end

  defp definition(opts) do
    opts = Keyword.validate!(opts, [:id, :subject, path: "/file.ex"])

    %Entry{
      id: Keyword.fetch!(opts, :id),
      subject: Keyword.fetch!(opts, :subject),
      path: Keyword.fetch!(opts, :path),
      type: :module,
      subtype: :definition,
      block_id: :root
    }
  end

  defp reference(opts) do
    %Entry{definition(opts) | subtype: :reference}
  end

  defp runtime_versions, do: %{erlang: "engine-erlang", elixir: "engine-elixir"}
end
