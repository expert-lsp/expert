defmodule Expert.Search.Store.Backends.SqliteTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Document.Position
  alias Forge.Document.Range
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
          SELECT def_blobs.entry
          FROM defs
          JOIN def_blobs ON def_blobs.entry_key = defs.entry_key
          WHERE type_id = (SELECT id FROM types WHERE type = ?)
          """,
          [{:blob, :erlang.term_to_binary(:module)}]
        )

      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      assert Enum.any?(rows, fn row ->
               plan = row |> List.last() |> to_string()

               String.contains?(plan, "defs_type_idx") and
                 String.contains?(plan, "type_id=?")
             end)
    end

    test "stores only entry data that is not available in the defs table", %{
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

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(defs)")
      assert {:ok, entry_columns, _columns} = Exqlite.Basic.rows(result)

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(def_blobs)")
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

      block_range = %Range{
        start: %Position{line: 1, character: 1},
        end: %Position{line: 2, character: 1}
      }

      range = %Range{
        start: %Position{line: 3, character: 1},
        end: %Position{line: 4, character: 1}
      }

      entry = %Entry{
        application: :sample,
        id: 1,
        block_id: :root,
        block_range: block_range,
        path: "/a/path/that/must/not/be/duplicated.ex",
        range: range,
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
      result = Exqlite.Basic.exec(conn, "SELECT entry FROM def_blobs")
      assert {:ok, [[entry_blob]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      # the positions' shared context line is stored once, and referenced by index
      assert {
               nil,
               :sample,
               {nil},
               {{1, 1, false, 0, 0, 1}, {2, 1, false, 0, 0, 1}},
               {{3, 1, false, 0, 0, 1}, {4, 1, false, 0, 0, 1}},
               %{detail: :kept}
             } = :erlang.binary_to_term(entry_blob)

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
      assert {:ok, [[7]], ["version"]} = Exqlite.Basic.rows(result)
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

    test "persists entries returned by encode_entries/1 the same as plain entries", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      entries =
        for id <- 1..5 do
          %Entry{
            id: id,
            subject: "Encoded.function_#{id}/0",
            path: "/encoded.ex",
            type: {:function, :public},
            subtype: :definition,
            block_id: :root
          }
        end

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      encoded = Sqlite.encode_entries(entries)
      assert Enum.all?(encoded, &match?({:encoded, %Entry{}, _row}, &1))

      assert :ok = Sqlite.replace_all(project, encoded)

      assert Enum.sort_by(
               Sqlite.find_by_subject(project, :_, {:function, :public}, :definition),
               & &1.id
             ) ==
               entries
    end

    test "finds references by subject, prefix, subjects and caller", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      range = fn line, from, to ->
        %Range{
          start: %Position{line: line, character: from},
          end: %Position{line: line, character: to}
        }
      end

      reference = fn fields ->
        struct!(
          %Entry{path: "/references.ex", subtype: :reference, block_id: 5, application: :app},
          fields
        )
      end

      call =
        reference.(
          id: 10,
          range: range.(3, 5, 25),
          subject: "Referenced.Target.run/1",
          type: {:function, :usage},
          caller: "Referenced.Caller.go/0"
        )

      call_module =
        reference.(id: 11, range: range.(3, 5, 18), subject: Referenced.Target, type: :module)

      plain_module =
        reference.(
          id: 12,
          block_id: :root,
          range: range.(4, 1, 14),
          subject: Referenced.Target,
          type: :module
        )

      nested_call =
        reference.(
          id: 13,
          range: range.(5, 5, 30),
          subject: "Referenced.Target.Inner.run/0",
          type: {:function, :usage},
          caller: "Referenced.Caller.go/0"
        )

      nested_module =
        reference.(
          id: 14,
          range: range.(5, 5, 24),
          subject: Referenced.Target.Inner,
          type: :module
        )

      entries = [call, call_module, plain_module, nested_call, nested_module]

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, Sqlite.encode_entries(entries))

      {:ok, conn} = Exqlite.Basic.open(Sqlite.database_path(project, runtime_versions))
      result = Exqlite.Basic.exec(conn, "SELECT count(*) FROM refs")
      assert {:ok, [[4]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      ids = fn found -> found |> Enum.map(& &1.id) |> Enum.sort() end

      assert Enum.sort_by(Sqlite.find_by_paths(project, ["/references.ex"], :_, :_), & &1.id) ==
               entries

      assert ids.(Sqlite.find_by_subject(project, Referenced.Target, :module, :reference)) == [
               11,
               12
             ]

      assert ids.(Sqlite.find_by_subject(project, Referenced.Target, :_, :_)) == [11, 12]
      assert ids.(Sqlite.find_by_subject(project, "Referenced.Target.run/1", :_, :_)) == [10]
      assert ids.(Sqlite.find_by_subject(project, :_, :module, :reference)) == [11, 12, 14]

      assert ids.(Sqlite.find_by_prefix(project, "Referenced.Target", :module, :reference)) == [
               11,
               12,
               14
             ]

      assert ids.(Sqlite.find_by_prefix(project, "Referenced.Target", :_, :_)) == [
               10,
               11,
               12,
               13,
               14
             ]

      assert ids.(
               Sqlite.find_by_subjects(
                 project,
                 [Referenced.Target, Referenced.Target.Inner],
                 :module,
                 :_
               )
             ) ==
               [11, 12, 14]

      assert ids.(
               Sqlite.find_by_caller(project, "Referenced.Caller.go/0", "/references.ex", :_, :_)
             ) == [
               10,
               13
             ]

      assert Sqlite.path_to_ids(project) == %{"/references.ex" => 14}
    end

    test "restores entries and indexes when replacement fails", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      old_entry = %Entry{
        id: 1,
        subject: Persisted.Module,
        path: "/persisted.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      invalid_entry = %Entry{
        id: 2,
        subject: Invalid.Module,
        path: nil,
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
      assert :ok = Sqlite.replace_all(project, [old_entry])
      spy(Exqlite.Basic)

      replacement = fn write_batch ->
        with :ok <- write_batch.([%Entry{old_entry | id: 3, subject: New.Module}]),
             :ok <- write_batch.([invalid_entry]) do
          {:ok, :replaced}
        end
      end

      assert {:error, _reason} = Sqlite.replace_all(project, replacement)

      assert_called(
        Exqlite.Basic.exec(_, "DROP INDEX IF EXISTS defs_caller_idx", []),
        1
      )

      assert [^old_entry] = Sqlite.find_by_subject(project, Persisted.Module, :_, :_)
      assert [] = Sqlite.find_by_subject(project, New.Module, :_, :_)

      database_path = Sqlite.database_path(project, runtime_versions)
      {:ok, conn} = Exqlite.Basic.open(database_path)
      result = Exqlite.Basic.exec(conn, "SELECT name FROM sqlite_master WHERE type = 'index'")
      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      index_names = MapSet.new(rows, fn [name] -> name end)

      assert MapSet.subset?(
               MapSet.new([
                 "defs_definitions_idx",
                 "defs_caller_idx",
                 "defs_id_idx",
                 "defs_file_block_idx",
                 "defs_type_idx",
                 "refs_subject_idx",
                 "refs_file_idx"
               ]),
               index_names
             )
    end
  end

  describe "replace_all/2 with references" do
    setup %{project: project, runtime_versions: runtime_versions} do
      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      :ok
    end

    test "reads callers back from the definitions written with them", %{project: project} do
      definition = fn id, subject, type ->
        %Entry{
          id: id,
          path: "/callers.ex",
          subject: subject,
          type: type,
          subtype: :definition,
          block_id: :root
        }
      end

      call = fn id, caller ->
        %Entry{
          id: id,
          path: "/callers.ex",
          subject: "Callee.run/0",
          type: {:function, :usage},
          subtype: :reference,
          block_id: :root,
          caller: caller
        }
      end

      entries = [
        definition.(1, Callers, :module),
        definition.(2, "Callers.go/1", {:function, :public}),
        # a function with a default argument: one id, one definition per arity
        definition.(3, "Callers.defaults/1", {:function, :public}),
        definition.(3, "Callers.defaults/2", {:function, :public}),
        call.(10, "Callers"),
        call.(11, "Callers.go/1"),
        call.(12, "Callers.defaults/1"),
        call.(13, "Callers.defaults/2"),
        call.(14, "/callers.ex"),
        call.(15, "Callers.undefined/0"),
        call.(16, nil)
      ]

      assert :ok = Sqlite.replace_all(project, entries)

      callers =
        project
        |> Sqlite.find_by_subject("Callee.run/0", :_, :reference)
        |> Map.new(&{&1.id, &1.caller})

      assert callers == Map.new(Enum.drop(entries, 4), &{&1.id, &1.caller})

      for caller <- [
            "Callers",
            "Callers.go/1",
            "Callers.defaults/2",
            "/callers.ex",
            "Callers.undefined/0"
          ] do
        assert [%Entry{caller: ^caller}] =
                 Sqlite.find_by_caller(project, caller, "/callers.ex", :_, :_)
      end
    end

    test "finds subjects by any prefix, across their module and name", %{project: project} do
      subjects = [
        "Foo.Bar.baz/1",
        "Foo.Barn.qux/0",
        "Foo.bar/2",
        "foo/1",
        "Kernel.../2",
        "Foo.Bar"
      ]

      entries =
        for {subject, id} <- Enum.with_index(subjects, 1) do
          %Entry{
            id: id,
            path: "/prefixes.ex",
            subject: subject,
            type: {:function, :usage},
            subtype: :reference,
            block_id: :root
          }
        end

      assert :ok = Sqlite.replace_all(project, entries)

      for prefix <- [
            "",
            "F",
            "Foo",
            "Foo.",
            "Foo.B",
            "Foo.Bar",
            "Foo.Bar.",
            "Foo.Bar.b",
            "Foo.b",
            "foo",
            "Kernel..",
            "Kernel...",
            "x"
          ] do
        found =
          project
          |> Sqlite.find_by_prefix(prefix, :_, :_)
          |> Enum.map(& &1.subject)
          |> Enum.sort()

        assert found == subjects |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort(),
               prefix
      end
    end
  end

  describe "replace_all/2 with indexed source entries" do
    test "handles modules defined with keyword do syntax", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      start_supervised!(Engine.ApplicationCache)
      {:ok, entries} = Expert.Search.Indexer.Source.index("/foo.ex", "defmodule Foo, do: :ok")

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      replacement = fn write_batch ->
        with :ok <- write_batch.(entries) do
          {:ok, :replaced}
        end
      end

      assert {:ok, :replaced} = Sqlite.replace_all(project, replacement)
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
        SELECT (SELECT COUNT(*) FROM defs), (SELECT COUNT(*) FROM def_blobs)
        """)

      assert {:ok, [[1, 1]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end

    test "replaces entries via streamed batch update", %{
      project: project,
      runtime_versions: runtime_versions
    } do
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

      update = fn write_batch ->
        with :ok <- write_batch.([new_entry]) do
          {:ok, :updated}
        end
      end

      assert {:ok, [1], :updated} = Sqlite.apply_index_update(project, update, ["/same.ex"])
      assert [] = Sqlite.find_by_subject(project, Replaced.Old, :_, :_)
      assert [^new_entry] = Sqlite.find_by_subject(project, Replaced.New, :_, :_)
    end

    test "clears more files than SQLite binds at once", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      paths = for index <- 1..40_000, do: "/many/file_#{index}.ex"

      entries =
        for {path, id} <- Enum.with_index(paths, 1) do
          %Entry{
            id: id,
            subject: "Many.function_#{id}/0",
            path: path,
            type: {:function, :public},
            subtype: :definition,
            block_id: :root
          }
        end

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, entries)

      update = fn write_batch ->
        with :ok <- write_batch.([]), do: {:ok, :updated}
      end

      assert {:ok, deleted_ids, :updated} = Sqlite.apply_index_update(project, update, paths)
      assert Enum.sort(deleted_ids) == Enum.to_list(1..40_000)
      assert Sqlite.path_to_ids(project) == %{}
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
        SELECT (SELECT COUNT(*) FROM defs), (SELECT COUNT(*) FROM def_blobs)
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
        result = Exqlite.Basic.exec(conn, "DROP INDEX defs_caller_idx")
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
            "defs_caller_idx"
          ])

        assert {:ok, [["defs_caller_idx"]], _columns} = Exqlite.Basic.rows(result)
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

  describe "find_by_prefix/4" do
    test "finds entries matching prefix", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      map = %Entry{
        id: 1,
        path: "/lib/enum.ex",
        subject: "Enum.map/2",
        type: {:function, :usage},
        subtype: :reference,
        block_id: :root
      }

      map_every = %Entry{
        id: 2,
        path: "/lib/enum.ex",
        subject: "Enum.map_every/3",
        type: {:function, :usage},
        subtype: :reference,
        block_id: :root
      }

      foo_bar = %Entry{
        id: 3,
        path: "/lib/foo.ex",
        subject: "Foo_bar/1",
        type: {:function, :usage},
        subtype: :reference,
        block_id: :root
      }

      foo_xbar = %Entry{
        id: 4,
        path: "/lib/foo.ex",
        subject: "FooXbar/1",
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
      assert :ok = Sqlite.replace_all(project, [map, map_every, foo_bar, foo_xbar])

      assert [^map] = Sqlite.find_by_prefix(project, "Enum.map/", :_, :_)
      assert [^map, ^map_every] = Sqlite.find_by_prefix(project, "Enum.map", :_, :_)
      assert [^foo_bar] = Sqlite.find_by_prefix(project, "Foo_", :_, :_)
      assert [] = Sqlite.find_by_prefix(project, "NonExistent", :_, :_)
    end

    test "matches ASCII and Unicode function names by their exact prefixes", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      entries =
        ["wien", "wieża", "wieść", "wiesz", "więcej", "Wieża"]
        |> Enum.with_index(1)
        |> Enum.map(fn {name, id} ->
          %Entry{
            id: id,
            path: "/lib/unicode.ex",
            subject: "Unicode.#{name}/0",
            type: {:function, :public},
            subtype: :definition,
            block_id: :root
          }
        end)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, entries)

      for {prefix, names} <- [
            {"wie", ["wien", "wieża", "wieść", "wiesz"]},
            {"wież", ["wieża"]},
            {"wieś", ["wieść"]},
            {"wien", ["wien"]},
            {"wieża", ["wieża"]},
            {"wieść", ["wieść"]},
            {"wieź", []}
          ] do
        subjects = Enum.map(names, &"Unicode.#{&1}/0")
        expected = Enum.filter(entries, &(&1.subject in subjects))

        actual =
          Sqlite.find_by_prefix(project, "Unicode.#{prefix}", {:function, :public}, :definition)

        assert Enum.sort_by(actual, & &1.id) == Enum.sort_by(expected, & &1.id),
               "unexpected matches for prefix #{inspect(prefix)}"
      end
    end

    test "matches Unicode prefixes whose byte successor is not valid UTF-8", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      entries =
        ["żółć", "ÿield", "þield", "żółty"]
        |> Enum.with_index(1)
        |> Enum.map(fn {name, id} ->
          %Entry{
            id: id,
            path: "/lib/unicode.ex",
            subject: "Unicode.#{name}/0",
            type: {:function, :public},
            subtype: :definition,
            block_id: :root
          }
        end)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, entries)

      for {prefix, names} <- [{"ż", ["żółć", "żółty"]}, {"ÿ", ["ÿield"]}] do
        # ż and ÿ end in 0xBF, so incrementing the last byte yields an invalid UTF-8 bound.
        subjects = Enum.map(names, &"Unicode.#{&1}/0")
        expected = Enum.filter(entries, &(&1.subject in subjects))

        actual = Sqlite.find_by_prefix(project, "Unicode.#{prefix}", :_, :_)
        assert Enum.sort_by(actual, & &1.id) == Enum.sort_by(expected, & &1.id)
      end
    end
  end
end
