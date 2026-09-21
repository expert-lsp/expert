defmodule Expert.Project.ReindexEventsTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Reindex
  alias Expert.Search
  alias Forge.Document

  setup do
    project = project()
    {:ok, store} = Agent.start_link(fn -> %{} end)

    patch(EngineApi, :register_listener, :ok)

    patch(Search.Store, :clear, fn ^project, path ->
      clear_store(store, path)
    end)

    patch(Search.Store, :update, fn ^project, path, entries ->
      update_store(store, path, entries)
    end)

    patch(Search.Store, :exact, fn ^project, subject, _constraints ->
      {:ok, exact_entries(store, subject)}
    end)

    patch(Search.Indexer, :document, fn ^project, uri ->
      with {:ok, document, analysis} <- Document.Store.fetch(uri, :analysis),
           {:ok, entries} <- Search.Indexer.Quoted.index_with_cleanup(analysis) do
        {:ok, document.path, entries}
      end
    end)

    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})

    start_supervised!(%{
      id: Reindex,
      start:
        {Reindex, :start_link,
         [project, [reindex_fun: fn _ -> :ok end, debounce_interval_millis: 0]]}
    })

    {:ok, project: project, store: store}
  end

  defp update_store(store, path, entries) do
    Agent.update(store, &Map.put(&1, path, entries))
    :ok
  end

  defp clear_store(store, path) do
    Agent.update(store, fn entries_by_path ->
      Map.reject(entries_by_path, fn {stored_path, entries} ->
        stored_path == path or Enum.any?(entries, &(&1.path == path))
      end)
    end)

    :ok
  end

  defp exact_entries(store, subject) do
    store
    |> Agent.get(& &1)
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(
      &(&1.type == :module and format_subject(&1.subject) == format_subject(subject))
    )
  end

  defp exact(store, subject) do
    {:ok, exact_entries(store, subject)}
  end

  def set_document!(source) do
    uri = "file:///file.ex"

    :ok =
      case Document.Store.fetch(uri) do
        {:ok, _} ->
          Document.Store.update(uri, fn doc ->
            edit = Document.Edit.new(source)
            Document.apply_content_changes(doc, doc.version + 1, [edit])
          end)

        {:error, :not_open} ->
          Document.Store.open(uri, source, 1)
      end

    {uri, source}
  end

  defp format_subject(subject) when is_atom(subject), do: Forge.Formats.module(subject)
  defp format_subject(subject) when is_binary(subject), do: subject
  defp format_subject(subject), do: to_string(subject)

  describe "handling file_quoted events" do
    test "should add new entries to the store", %{project: project, store: store} do
      {uri, _source} =
        ~q[
          defmodule NewModule do
          end
        ]
        |> set_document!()

      send(Reindex.name(project), file_compile_requested(uri: uri))

      assert_eventually {:ok, [entry]} = exact(store, "NewModule")

      assert entry.subject == NewModule
    end

    test "should update entries in the store", %{project: project, store: store} do
      {uri, source} =
        ~q[
          defmodule OldModule
          end
        ]
        |> set_document!()

      {:ok, old_entries} = Search.Indexer.Source.index(uri, source)
      update_store(store, Document.Path.ensure_path(uri), old_entries)

      {^uri, _source} =
        ~q[
          defmodule UpdatedModule do
          end
        ]
        |> set_document!()

      send(Reindex.name(project), file_compile_requested(uri: uri))

      assert_eventually {:ok, [entry]} = exact(store, "UpdatedModule")
      assert entry.subject == UpdatedModule
      assert {:ok, []} = exact(store, "OldModule")
    end

    test "only updates entries if the version of the document is the same as the version in the document store",
         %{project: project, store: store} do
      Document.Store.open("file:///file.ex", "defmodule Newer do \nend", 3)

      {uri, _source} =
        ~q[
          defmodule Stale do
          end
        ]
        |> set_document!()

      send(Reindex.name(project), file_compile_requested(uri: uri))
      assert {:ok, []} = exact(store, "Stale")
    end
  end

  describe "a file is deleted" do
    test "its entries should be deleted", %{project: project, store: store} do
      {uri, source} =
        ~q[
          defmodule ToDelete do
          end
        ]
        |> set_document!()

      {:ok, entries} = Search.Indexer.Source.index(uri, source)
      update_store(store, uri, entries)

      assert_eventually {:ok, [_]} = exact(store, "ToDelete")

      send(
        Reindex.name(project),
        filesystem_event(project: project, uri: uri, event_type: :deleted)
      )

      assert_eventually {:ok, []} = exact(store, "ToDelete")
    end
  end

  describe "a file is created" do
    test "is a no op", %{project: project, store: store} do
      spy(Search.Indexer)

      event = filesystem_event(project: project, uri: "file:///another.ex", event_type: :created)

      send(Reindex.name(project), event)
      Process.sleep(10)

      assert Agent.get(store, & &1) == %{}
      assert history(Search.Indexer) == []
    end
  end
end
