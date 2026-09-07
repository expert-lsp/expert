defmodule Expert.Search.Store.Backends.SqliteTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    runtime_versions = %{erlang: "engine-erlang", elixir: "engine-elixir"}

    Sqlite.destroy_all(project)
    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project, runtime_versions: runtime_versions}
  end

  describe "prepare/1" do
    test "creates an index for wildcard subject searches constrained by type and subtype", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(
          conn,
          """
          EXPLAIN QUERY PLAN
          SELECT entry_blobs.entry
          FROM entries
          JOIN entry_blobs ON entry_blobs.entry_key = entries.entry_key
          WHERE type = ? AND subtype = ?
          """,
          [{:blob, :erlang.term_to_binary(:module)}, "definition"]
        )

      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      assert Enum.any?(rows, fn row ->
               plan = row |> List.last() |> to_string()

               String.contains?(plan, "entries_type_subtype_idx") and
                 String.contains?(plan, "type=?") and
                 String.contains?(plan, "subtype=?")
             end)
    end

    test "stores only entry data that is not available in the entries table", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      {:ok, conn} = Exqlite.Basic.open(database_path)

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(entries)")
      assert {:ok, entry_columns, _columns} = Exqlite.Basic.rows(result)

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(entry_blobs)")
      assert {:ok, blob_columns, _columns} = Exqlite.Basic.rows(result)

      assert :ok = Exqlite.Basic.close(conn)

      refute Enum.any?(entry_columns, fn [_cid, name | _] -> name == "entry" end)

      assert Enum.any?(entry_columns, fn [_cid, name, type | _] ->
               name == "entry_key" and type == "INTEGER"
             end)

      assert Enum.any?(entry_columns, fn [_cid, name, type | _] ->
               name == "id" and type == "INTEGER"
             end)

      assert Enum.any?(blob_columns, fn [_cid, name | _] -> name == "entry" end)

      assert Enum.any?(blob_columns, fn [_cid, name, type | _] ->
               name == "entry_key" and type == "INTEGER"
             end)
    end

    test "stores entry caller", %{project: project, runtime_versions: runtime_versions} do
      entry = %Entry{
        id: 1,
        block_id: :root,
        path: "/orders.ex",
        subject: "Payments.charge/1",
        caller: "Orders.checkout/1",
        type: {:function, :usage},
        subtype: :reference
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [entry])

      assert [^entry] =
               Sqlite.find_by_subject(
                 project,
                 "Payments.charge/1",
                 {:function, :usage},
                 :reference
               )
    end

    test "stores lean entry blobs and reconstructs entries from both tables", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      entry = %Entry{
        application: :sample,
        id: 1,
        block_id: :root,
        block_range: %{start: 1, end: 2},
        path: "/a/path/that/must/not/be/duplicated.ex",
        range: %{start: 3, end: 4},
        subject: "Lean.Module.function/0",
        subtype: :definition,
        type: :module,
        metadata: %{detail: :kept}
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [entry])

      {:ok, conn} = Exqlite.Basic.open(database_path)
      result = Exqlite.Basic.exec(conn, "SELECT entry FROM entry_blobs")
      assert {:ok, [[entry_blob]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      assert {nil, :sample, %{start: 1, end: 2}, %{start: 3, end: 4}, %{detail: :kept}} =
               :erlang.binary_to_term(entry_blob)

      assert [^entry] = Sqlite.find_by_subject(project, "Lean.Module.function/0", :_, :_)
    end

    test "recreates a database with a different schema version", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      File.mkdir_p!(Path.dirname(database_path))
      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(conn, """
        CREATE TABLE schema (
          id INTEGER PRIMARY KEY,
          version INTEGER NOT NULL,
          inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """)

      assert {:ok, [], []} = Exqlite.Basic.rows(result)

      result = Exqlite.Basic.exec(conn, "INSERT INTO schema (version) VALUES (?)", [999])
      assert {:ok, [], []} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert Path.basename(database_path) == "source.index.sqlite3"

      {:ok, conn} = Exqlite.Basic.open(database_path)
      result = Exqlite.Basic.exec(conn, "SELECT version FROM schema")
      assert {:ok, [[5]], ["version"]} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end
  end

  describe "replace_all/2" do
    test "persists entries", %{project: project, runtime_versions: runtime_versions} do
      entry = %Entry{
        id: 1,
        subject: Persisted.Module,
        path: "/persisted.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [entry])
      assert :ok = stop_supervised!(:sqlite)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :stale} = Sqlite.prepare(pid)
      assert [^entry] = Sqlite.find_by_subject(project, Persisted.Module, :_, :_)
    end
  end

  describe "replace_all/2 with indexed source entries" do
    test "handles modules defined with keyword do syntax", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      start_supervised!(Engine.ApplicationCache)
      {:ok, entries} = Engine.Search.Indexer.Source.index("/foo.ex", "defmodule Foo, do: :ok")

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, entries)
    end
  end

  describe "insert/2" do
    test "persists entries", %{project: project, runtime_versions: runtime_versions} do
      entry = %Entry{
        id: 1,
        subject: Incremental.Module,
        path: "/incremental.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.insert(project, [entry])
      assert :ok = stop_supervised!(:sqlite)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :stale} = Sqlite.prepare(pid)
      assert [^entry] = Sqlite.find_by_subject(project, Incremental.Module, :_, :_)
    end
  end

  describe "apply_index_update/3" do
    test "replaces entries by path", %{project: project, runtime_versions: runtime_versions} do
      old_entry = %Entry{
        id: 1,
        subject: Replaced.Old,
        path: "/same.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      new_entry = %Entry{
        id: 2,
        subject: Replaced.New,
        path: "/same.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      assert {:ok, []} = Sqlite.apply_index_update(project, [old_entry], [])
      assert {:ok, [1]} = Sqlite.apply_index_update(project, [new_entry], [])

      assert [] = Sqlite.find_by_subject(project, Replaced.Old, :_, :_)
      assert [^new_entry] = Sqlite.find_by_subject(project, Replaced.New, :_, :_)

      database_path = Sqlite.database_path(project, runtime_versions)
      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(conn, """
        SELECT (SELECT COUNT(*) FROM entries), (SELECT COUNT(*) FROM entry_blobs)
        """)

      assert {:ok, [[1, 1]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end

    test "chunks blob deletes that exceed SQLite's variable limit", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      path = "/large_generated.ex"

      old_entries =
        Enum.map(1..32_767, fn id ->
          %Entry{
            id: id,
            subject: "Old",
            path: path,
            type: :module,
            subtype: :definition,
            block_id: :root
          }
        end)

      new_entry = %Entry{
        id: 32_768,
        subject: "New",
        path: path,
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, old_entries)
      assert {:ok, deleted_ids} = Sqlite.apply_index_update(project, [new_entry], [])
      assert length(deleted_ids) == 32_767
      assert [] = Sqlite.find_by_subject(project, "Old", :_, :_)
      assert [^new_entry] = Sqlite.find_by_subject(project, "New", :_, :_)

      database_path = Sqlite.database_path(project, runtime_versions)
      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(conn, """
        SELECT (SELECT COUNT(*) FROM entries), (SELECT COUNT(*) FROM entry_blobs)
        """)

      assert {:ok, [[1, 1]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end
  end

  describe "parent/2" do
    test "returns the containing entry", %{project: project, runtime_versions: runtime_versions} do
      path = "/blocks.ex"

      parent = %Entry{
        id: 1,
        subject: Parent,
        path: path,
        type: :module,
        subtype: :definition,
        block_id: 1
      }

      child = %Entry{
        id: 2,
        subject: Parent.Child,
        path: path,
        type: :module,
        subtype: :definition,
        block_id: 2
      }

      structure = Entry.block_structure(path, %{1 => %{2 => %{}}})

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [parent, child, structure])

      assert {:ok, ^parent} = Sqlite.parent(project, child)
    end
  end

  describe "structure_for_path/2" do
    test "returns the block structure", %{project: project, runtime_versions: runtime_versions} do
      path = "/blocks.ex"
      structure = Entry.block_structure(path, %{1 => %{2 => %{}}})

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [structure])

      assert {:ok, %{1 => %{2 => %{}}}} = Sqlite.structure_for_path(project, path)
    end
  end

  describe "find_by_caller/5" do
    test "adds the caller index to an existing database without losing entries", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      entry = %Entry{
        id: 1,
        subject: "Payments.charge/1",
        caller: "Orders.odd'_%/1",
        path: "/orders'_%/file.ex",
        type: {:function, :usage},
        subtype: :reference,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [entry])
      assert :ok = stop_supervised!(:sqlite)

      {:ok, conn} = Exqlite.Basic.open(Sqlite.database_path(project, runtime_versions))

      try do
        # Simulate a persisted database created before the caller index was added.
        result = Exqlite.Basic.exec(conn, "DROP INDEX entries_caller_idx")
        assert {:ok, [], _columns} = Exqlite.Basic.rows(result)
      after
        Exqlite.Basic.close(conn)
      end

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :stale} = Sqlite.prepare(pid)

      assert [^entry] =
               Sqlite.find_by_caller(project, entry.caller, entry.path, :_, :reference)

      assert [] = Sqlite.find_by_caller(project, "Orders.oddX_%/1", entry.path, :_, :reference)

      {:ok, conn} = Exqlite.Basic.open(Sqlite.database_path(project, runtime_versions))

      try do
        result =
          Exqlite.Basic.exec(conn, "SELECT name FROM sqlite_master WHERE name = ?", [
            "entries_caller_idx"
          ])

        assert {:ok, [["entries_caller_idx"]], _columns} = Exqlite.Basic.rows(result)
      after
        Exqlite.Basic.close(conn)
      end
    end
  end

  describe "find_by_subjects/4" do
    setup %{project: project, runtime_versions: runtime_versions} do
      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      :ok
    end

    test "matches exact subjects without collapsing clauses or duplicating entries", %{
      project: project
    } do
      first = %Entry{
        id: 1,
        subject: "Orders.checkout/1",
        path: "/orders.ex",
        type: {:function, :public},
        subtype: :definition,
        block_id: :root
      }

      second = %{first | id: 2}
      other = %{first | id: 3, subject: "Jobs.retry/1", path: "/jobs.ex"}
      other_path = %{first | id: 4, path: "/other/orders.ex"}

      reference = %{
        first
        | id: 5,
          subtype: :reference,
          type: {:function, :usage},
          caller: "Jobs.retry/1"
      }

      macro = %{first | id: 6, type: {:macro, :public}}
      other_arity = %{first | id: 7, subject: "Orders.checkout/2"}
      literal = %{first | id: 8, subject: "odd'_%/0"}
      module = %{first | id: 9, subject: Orders, type: :module}

      assert :ok =
               Sqlite.replace_all(project, [
                 first,
                 second,
                 other,
                 other_path,
                 reference,
                 macro,
                 other_arity,
                 literal,
                 module
               ])

      subjects = ["Jobs.retry/1", "Orders.checkout/1", "Orders.checkout/1", "Missing.function/0"]

      assert [^first, ^second, ^other, ^other_path] =
               project
               |> Sqlite.find_by_subjects(subjects, {:function, :public}, :definition)
               |> Enum.sort_by(& &1.id)

      assert [^first, ^second, ^other, ^other_path, ^reference, ^macro] =
               project
               |> Sqlite.find_by_subjects(subjects, :_, :_)
               |> Enum.sort_by(& &1.id)

      assert [^reference] = Sqlite.find_by_subjects(project, subjects, :_, :reference)
      assert [^literal] = Sqlite.find_by_subjects(project, ["odd'_%/0"], :_, :_)
      assert [^module] = Sqlite.find_by_subjects(project, [Orders, "Orders"], :_, :_)
      assert [] = Sqlite.find_by_subjects(project, ["Orders.checkout"], :_, :_)
      assert [] = Sqlite.find_by_subjects(project, [], :_, :_)
    end

    test "batches subjects within the parameter limit and retains matches from every batch", %{
      project: project
    } do
      subjects = Enum.map(1..32_767, &"Generated.function_#{&1}/0")

      entries =
        for id <- [1, 32_765, 32_767] do
          %Entry{
            id: id,
            subject: "Generated.function_#{id}/0",
            path: "/generated.ex",
            type: {:function, :public},
            subtype: :definition,
            block_id: :root
          }
        end

      assert :ok = Sqlite.replace_all(project, entries)
      subjects = subjects ++ ["Generated.function_1/0"]

      for {type, subtype} <- [
            {:_, :_},
            {{:function, :public}, :_},
            {:_, :definition},
            {{:function, :public}, :definition}
          ] do
        assert ^entries =
                 project
                 |> Sqlite.find_by_subjects(subjects, type, subtype)
                 |> Enum.sort_by(& &1.id)
      end
    end
  end

  describe "find_by_ids/4" do
    test "preserves input order", %{project: project, runtime_versions: runtime_versions} do
      one = %Entry{
        id: 1,
        subject: One,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      two = %Entry{
        id: 2,
        subject: Two,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      three = %Entry{
        id: 3,
        subject: Three,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [one, two, three])

      assert [^three, ^one, ^three] = Sqlite.find_by_ids(project, [3, 1, 3], :_, :definition)
    end
  end

  describe "find_by_paths/4" do
    test "chunks path lists that exceed SQLite's variable limit", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      paths = Enum.map(1..32_767, &"/generated/#{&1}.ex")

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert [] = Sqlite.find_by_paths(project, paths, :module, :definition)
    end
  end
end
