defmodule Expert.Project.ReindexTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Progress
  alias Expert.Project.Reindex
  alias Expert.Search.Indexer
  alias Expert.Search.Store
  alias Forge.Document
  alias Forge.Search.Indexer.Entry

  setup context do
    debounce_interval_millis = Map.get(context, :debounce_interval_millis, 0)
    project = project()
    patch(EngineApi, :register_listener, :ok)
    patch(Progress, :begin, fn _title, _opts -> {:ok, System.unique_integer([:positive])} end)
    patch(Progress, :report, :ok)
    patch(Progress, :complete, :ok)

    case Map.get(context, :reindex_fun, :sleep) do
      :default ->
        start_reindex!(project, debounce_interval_millis: debounce_interval_millis)

      :none ->
        :ok

      :sleep ->
        start_reindex!(project,
          reindex_fun: fn _ -> Process.sleep(20) end,
          debounce_interval_millis: debounce_interval_millis
        )
    end

    {:ok, project: project}
  end

  test "it should allow reindexing", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert Reindex.running?(project)
  end

  test "it fails if another index is running", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert {:error, "Already Running"} = Reindex.perform(project)
  end

  test "it eventually becomes available", %{project: project} do
    assert :ok = Reindex.perform(project)
    refute_eventually Reindex.running?(project)
  end

  test "another reindex can be enqueued", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert_eventually :ok = Reindex.perform(project)
  end

  def put_entries(uri, entries) do
    Process.put(uri, entries)
  end

  describe "uri/1" do
    setup do
      test = self()

      patch(Reindex.State, :entries_for_uri, fn _project, uri ->
        entries =
          test
          |> Process.info()
          |> get_in([:dictionary])
          |> Enum.find_value(fn
            {^uri, value} -> value
            _ -> nil
          end)

        {:ok, Document.Path.ensure_path(uri), entries || []}
      end)

      patch(Store, :update, fn _project, uri, entries ->
        send(test, {:entries, uri, entries})
      end)

      :ok
    end

    test "reindexes a specific uri", %{project: project} do
      uri = "file:///file.ex"
      path = Document.Path.ensure_path(uri)
      entries = [reference()]
      put_entries(uri, entries)
      Reindex.uri(project, uri)
      assert_receive {:entries, ^path, ^entries}
    end

    test "buffers updates if a reindex is in progress", %{project: project} do
      uri = "file:///file.ex"
      path = Document.Path.ensure_path(uri)
      new_entries = [reference(), definition()]
      put_entries(uri, new_entries)
      Reindex.perform(project)
      Reindex.uri(project, uri)

      assert_receive {:entries, ^path, ^new_entries}
    end
  end

  describe "perform/1 with the default reindexer" do
    @tag reindex_fun: :default
    test "broadcasts success when refreshing the search index succeeds", %{project: project} do
      patch(Indexer, :create_index, fn ^project -> {:ok, [], :manifest} end)
      patch(Indexer, :commit_manifest, fn ^project, :manifest -> :ok end)
      patch(Store, :replace, fn ^project, [] -> :ok end)

      test_pid = self()

      patch(EngineApi, :broadcast, fn ^project, message ->
        send(test_pid, {:broadcast, message})
        :ok
      end)

      assert :ok = Reindex.perform(project)

      assert_receive {:broadcast, project_reindex_requested(project: ^project)}
      assert_receive {:broadcast, project_reindexed(project: ^project, status: :success)}
    end

    @tag reindex_fun: :default
    test "broadcasts the error when refreshing the search index fails", %{project: project} do
      patch(Indexer, :create_index, fn ^project -> {:error, :refresh_failed} end)

      test_pid = self()

      patch(EngineApi, :broadcast, fn ^project, message ->
        send(test_pid, {:broadcast, message})
        :ok
      end)

      assert :ok = Reindex.perform(project)

      assert_receive {:broadcast, project_reindex_requested(project: ^project)}

      assert_receive {:broadcast,
                      project_reindexed(project: ^project, status: {:error, :refresh_failed})}
    end

    @tag reindex_fun: :default
    test "does not commit the manifest when replacing the search store fails", %{project: project} do
      test_pid = self()

      patch(Indexer, :create_index, fn ^project -> {:ok, [], :manifest} end)

      patch(Indexer, :commit_manifest, fn ^project, :manifest ->
        send(test_pid, :commit_manifest)
        :ok
      end)

      patch(Store, :replace, fn ^project, [] ->
        {:error, :replace_failed}
      end)

      patch(EngineApi, :broadcast, fn ^project, message ->
        send(test_pid, {:broadcast, message})
        :ok
      end)

      assert :ok = Reindex.perform(project)

      assert_receive {:broadcast, project_reindex_requested(project: ^project)}

      assert_receive {:broadcast,
                      project_reindexed(project: ^project, status: {:error, :replace_failed})}

      refute_receive :commit_manifest
    end
  end

  defp start_reindex!(project, opts) do
    start_supervised!(%{
      id: Reindex,
      start: {Reindex, :start_link, [project, opts]}
    })
  end

  defp reference, do: %Entry{subtype: :reference}
  defp definition, do: %Entry{subtype: :definition}
end
