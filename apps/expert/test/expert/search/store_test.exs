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
    assert_eventually Store.loaded?(project), 1500

    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project}
  end

  test "replaces and queries entries", %{project: project} do
    entries = [definition(id: 1, subject: Foo.Bar), reference(id: 2, subject: Foo.Bar)]

    assert :ok = Store.replace(project, entries)

    assert {:ok, [entry]} = Store.exact(project, "Foo.Bar", subtype: :definition)
    assert entry.id == 1
  end

  test "exact_many uses one indexed query and skips SQL for empty input", %{project: project} do
    one = definition(id: 1, subject: Foo.Bar)
    two = definition(id: 2, subject: Other.Module)

    entries = [
      one,
      two,
      reference(id: 3, subject: Foo.Bar),
      definition(id: 4, subject: Unrelated)
    ]

    assert :ok = Store.replace(project, entries)
    spy(Exqlite.Basic)

    assert {:ok, []} = Store.exact_many(project, [], [])
    refute_called(Exqlite.Basic.exec(_, _, _))

    assert {:ok, matches} =
             Store.exact_many(project, ["Foo.Bar", "Other.Module", "Foo.Bar"],
               type: :module,
               subtype: :definition
             )

    assert [^one, ^two] = Enum.sort_by(matches, & &1.id)
    assert_called(Exqlite.Basic.exec(_, sql, args), 1)

    {:ok, conn} = Exqlite.Basic.open(Sqlite.database_path(project, runtime_versions()))

    try do
      result = Exqlite.Basic.exec(conn, "EXPLAIN QUERY PLAN " <> sql, args)
      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)

      assert Enum.any?(rows, fn [_id, _parent, _unused, detail] ->
               String.contains?(detail, "SEARCH entries USING INDEX entries_subject_idx") and
                 String.contains?(detail, "subject=?")
             end)
    after
      Exqlite.Basic.close(conn)
    end
  end

  test "exact_many follows the disabled store behavior", %{project: project} do
    assert :ok = Store.destroy(project)
    assert [] = Store.exact_many(project, ["Foo.Bar"], [])
    assert :ok = Store.enable(project)
    assert {:ok, []} = Store.exact_many(project, ["Foo.Bar"], [])
  end

  test "exact_many propagates SQL failures", %{project: project} do
    patch(Exqlite.Basic, :exec, fn _conn, _sql, _args -> {:error, :busy, nil} end)

    assert {:error, :busy} = Store.exact_many(project, ["Foo.Bar"], [])
  end

  test "by_caller returns only matching occurrences using the caller index", %{project: project} do
    first = %Entry{
      id: 1,
      block_id: :root,
      path: "/core.ex",
      caller: "Core.public/1",
      subject: "Core.private/2",
      type: {:function, :usage},
      subtype: :reference,
      range: %{start: 1, end: 2}
    }

    second = %{first | id: 2, subject: "Core.Piece.new/2", range: %{start: 3, end: 4}}
    repeated = %{second | id: 3, block_id: 123, range: %{start: 5, end: 6}}
    other_caller = %{first | id: 4, caller: "Core.public/2"}
    other_path = %{first | id: 5, path: "/other/core.ex"}
    no_caller = %{first | id: 6, caller: nil}
    definition = %{first | id: 7, subtype: :definition}
    other_type = %{first | id: 8, type: :module}

    assert :ok =
             Store.replace(project, [
               first,
               second,
               repeated,
               other_caller,
               other_path,
               no_caller,
               definition,
               other_type
             ])

    spy(Exqlite.Basic)

    assert {:ok, matches} =
             Store.by_caller(project, "Core.public/1", "/core.ex",
               type: {:function, :usage},
               subtype: :reference
             )

    assert [^first, ^second, ^repeated] = Enum.sort_by(matches, & &1.id)
    assert_called(Exqlite.Basic.exec(_, sql, args), 1)

    {:ok, conn} = Exqlite.Basic.open(Sqlite.database_path(project, runtime_versions()))

    try do
      result = Exqlite.Basic.exec(conn, "EXPLAIN QUERY PLAN " <> sql, args)
      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)

      assert Enum.any?(rows, fn [_id, _parent, _unused, detail] ->
               String.contains?(detail, "SEARCH entries USING INDEX entries_caller_idx") and
                 String.contains?(detail, "caller=? AND path=?")
             end)
    after
      Exqlite.Basic.close(conn)
    end

    assert {:ok, matches} = Store.by_caller(project, "Core.public/1", "/core.ex")
    assert [^first, ^second, ^repeated, ^definition, ^other_type] = Enum.sort_by(matches, & &1.id)
    assert {:ok, []} = Store.by_caller(project, "Core.public", "/core.ex")
    assert {:ok, []} = Store.by_caller(project, "Core.public/1", "/missing.ex")
  end

  test "by_caller follows store availability and propagates SQL failures", %{project: project} do
    assert :ok = Store.destroy(project)
    assert [] = Store.by_caller(project, "Core.public/1", "/core.ex")
    assert :ok = Store.enable(project)
    assert {:ok, []} = Store.by_caller(project, "Core.public/1", "/core.ex")

    patch(Exqlite.Basic, :exec, fn _conn, _sql, _args -> {:error, :busy, nil} end)

    assert {:error, :busy} = Store.by_caller(project, "Core.public/1", "/core.ex")
  end

  test "updates replace entries for the same path", %{project: project} do
    path = "/path/to/file.ex"

    assert :ok = Store.replace(project, [definition(id: 1, subject: Old.Module, path: path)])
    assert :ok = Store.update(project, path, [definition(id: 2, subject: New.Module, path: path)])
    send(Process.whereis(Store.name(project)), :flush_updates)

    assert_eventually {:ok, [entry]} =
                        Store.fuzzy(project, "New", type: :module, subtype: :definition)

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
