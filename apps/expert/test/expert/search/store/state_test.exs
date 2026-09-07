defmodule Expert.Search.Store.StateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Forge.Test.Fixtures

  alias Expert.Search.Fuzzy
  alias Expert.Search.Store.State
  alias Forge.Search.Indexer.Entry

  defmodule QueryBackend do
    @behaviour Expert.Search.Store.Backend

    def delete_by_path(_project, _path), do: {:ok, []}
    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}
    def insert(_project, _entries), do: :ok
    def replace_all(_project, _entries), do: :ok

    def apply_index_update(_project, _entries, _paths),
      do: {:ok, []}

    def find_by_subject(_project, :_, :module, :definition), do: [entry(1)]
    def find_by_subject(_project, _subject, _type, _subtype), do: []
    def find_by_subjects(_project, ["QueryBackend.Result"], :module, :definition), do: [entry(4)]
    def find_by_subjects(_project, ["error"], :_, :_), do: {:error, :busy}
    def find_by_subjects(_project, _subjects, _type, _subtype), do: []

    def find_by_caller(
          _project,
          "QueryBackend.Result",
          "/query_backend.ex",
          :module,
          :definition
        ),
        do: [entry(5)]

    def find_by_caller(_project, "error", _path, :_, :_), do: {:error, :busy}
    def find_by_caller(_project, _caller, _path, _type, _subtype), do: []
    def find_by_prefix(_project, _prefix, _type, _subtype), do: []
    def find_by_ids(_project, [2], :module, :definition), do: [entry(2)]
    def find_by_ids(_project, _ids, _type, _subtype), do: []
    def find_by_paths(_project, ["/query_backend.ex"], :module, :definition), do: [entry(3)]
    def find_by_paths(_project, _paths, _type, _subtype), do: []
    def path_to_ids(_project), do: %{}
    def definitions_for_fuzzy(_project), do: []
    def siblings(_project, _entry), do: []
    def parent(_project, _entry), do: nil
    def structure_for_path(_project, _path), do: {:ok, %{}}
    def drop(_project), do: :ok
    def destroy(_project), do: :ok

    defp entry(id) do
      %Entry{
        id: id,
        subject: QueryBackend.Result,
        path: "/query_backend.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }
    end
  end

  defmodule NotStartedBackend do
    @behaviour Expert.Search.Store.Backend

    def new(_project), do: {:error, :not_started}
    def prepare(_), do: exit(:prepare_should_not_be_called)
    def delete_by_path(_project, _path), do: {:ok, []}
    def insert(_project, _entries), do: :ok
    def replace_all(_project, _entries), do: :ok

    def apply_index_update(_project, _entries, _paths),
      do: {:ok, []}

    def find_by_subject(_project, _subject, _type, _subtype), do: []
    def find_by_subjects(_project, _subjects, _type, _subtype), do: []
    def find_by_caller(_project, _caller, _path, _type, _subtype), do: []
    def find_by_prefix(_project, _prefix, _type, _subtype), do: []
    def find_by_ids(_project, _ids, _type, _subtype), do: []
    def find_by_paths(_project, _paths, _type, _subtype), do: []
    def path_to_ids(_project), do: %{}
    def definitions_for_fuzzy(_project), do: []
    def siblings(_project, _entry), do: []
    def parent(_project, _entry), do: nil
    def structure_for_path(_project, _path), do: {:ok, %{}}
    def drop(_project), do: :ok
    def destroy(_project), do: :ok
  end

  test "load/1 returns backend startup errors" do
    Logger.put_module_level(State, :error)
    on_exit(fn -> Logger.put_module_level(State, Logger.level()) end)

    state = State.new(project(), NotStartedBackend)

    assert {{:error, :not_started}, log} = with_log(fn -> State.load(state) end)
    assert log =~ "Could not initialize index backend"
  end

  test "exact_many forwards filters, wraps entries, and preserves backend errors" do
    state = State.new(project(), QueryBackend)

    assert {:error, :loading} = State.exact_many(state, ["QueryBackend.Result"], [])

    state = %{state | loaded?: true}

    assert {:ok, [%Entry{id: 4}]} =
             State.exact_many(state, ["QueryBackend.Result"], type: :module, subtype: :definition)

    assert {:ok, []} = State.exact_many(state, [], [])
    assert {:error, :busy} = State.exact_many(state, ["error"], [])
  end

  test "by_caller forwards caller, path, and filters and preserves errors" do
    state = State.new(project(), QueryBackend)
    caller = "QueryBackend.Result"
    path = "/query_backend.ex"

    assert {:error, :loading} = State.by_caller(state, caller, path, [])

    state = %{state | loaded?: true}

    assert {:ok, [%Entry{id: 5}]} =
             State.by_caller(state, caller, path, type: :module, subtype: :definition)

    assert {:ok, []} = State.by_caller(state, caller, "/other.ex", [])
    assert {:error, :busy} = State.by_caller(state, "error", path, [])
  end

  test "all reduces backend entries and fuzzy uses in-memory ids" do
    project = project()

    fuzzy_entry = %Entry{
      id: 2,
      subject: QueryBackend.FuzzyNeedle,
      path: "/query_backend.ex",
      type: :module,
      subtype: :definition,
      block_id: :root
    }

    state = %State{
      State.new(project, QueryBackend)
      | loaded?: true,
        fuzzy: Fuzzy.from_entries(project, [fuzzy_entry])
    }

    assert {:ok, [%Entry{id: 1}]} = State.all(state, type: :module, subtype: :definition)

    assert {:ok, [%Entry{id: 3}]} =
             State.all(state, paths: ["/query_backend.ex"], type: :module, subtype: :definition)

    assert {:ok, [%Entry{id: 2}]} =
             State.fuzzy(state, "Needle", type: :module, subtype: :definition)
  end
end
