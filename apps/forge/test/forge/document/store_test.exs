defmodule Forge.Document.StoreTest do
  use ExUnit.Case

  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  def with_store(%{} = context) do
    store_opts = Map.get(context, :store, [])
    {:ok, _} = start_supervised({Document.Store, store_opts})
    :ok
  end

  def with_an_open_document(_) do
    :ok = Document.Store.open(uri(), "hello", 1)
  end

  def uri do
    "file:///file.ex"
  end

  defp build_position(_, nil) do
    nil
  end

  defp build_position(%Document{} = document, opts) do
    line = Keyword.get(opts, :line)
    character = Keyword.get(opts, :character)
    Position.new(document, line, character)
  end

  defp build_range(_, nil) do
    nil
  end

  defp build_range(%Document{} = document, opts) do
    start_pos = build_position(document, Keyword.get(opts, :start))

    end_pos = build_position(document, Keyword.get(opts, :end))

    Range.new(start_pos, end_pos)
  end

  defp build_change(opts) do
    text = Keyword.get(opts, :text, "")
    document = Document.new("file:///file.ex", text, 1)

    range = build_range(document, Keyword.get(opts, :range))
    Edit.new(text, range)
  end

  describe "startup" do
    test "succeeds without options" do
      assert {:ok, _} = start_supervised(Document.Store)
    end

    test "succeeds with empty :derive" do
      assert {:ok, _} = start_supervised({Document.Store, [derive: []]})
    end

    test "succeeds with valid :derive" do
      valid_fun = fn _ -> :ok end
      assert {:ok, _} = start_supervised({Document.Store, [derive: [valid: valid_fun]]})
    end

    test "fails with invalid :derive" do
      invalid_fun = fn _, _ -> :ok end
      assert {:error, _} = start_supervised({Document.Store, [derive: [invalid: invalid_fun]]})
    end

    test "fails with invalid options" do
      assert {:error, _} = start_supervised({Document.Store, [invalid: []]})
    end
  end

  describe "a clean store" do
    setup [:with_store]

    test "a document can be opened" do
      :ok = Document.Store.open(uri(), "hello", 1)
      assert {:ok, file} = Document.Store.fetch(uri())
      assert Document.to_string(file) == "hello"
      assert file.version == 1
    end

    test "rejects changes to a file that isn't open" do
      event = build_change(text: "dog", range: nil)

      assert {:error, :not_open} =
               Document.Store.get_and_update(
                 "file:///another.ex",
                 &Document.apply_content_changes(&1, 3, [event])
               )
    end
  end

  describe "a document that is already open" do
    setup [:with_store, :with_an_open_document]

    test "can be fetched" do
      assert {:ok, doc} = Document.Store.fetch(uri())
      assert doc.uri == uri()
      assert Document.to_string(doc) == "hello"
    end

    test "is identified as open when fetched with its origin" do
      assert {:ok, %Document{version: 1}, :open} = Document.Store.fetch_with_origin(uri())
    end

    test "can be closed" do
      assert :ok = Document.Store.close(uri())
      assert {:error, :not_open} = Document.Store.fetch(uri())
    end

    test "can be saved" do
      assert :ok = Document.Store.save(uri())
      assert {:ok, %{dirty?: false}} = Document.Store.fetch(uri())
    end

    test "can have its content changed" do
      event =
        build_change(
          text: "dog",
          range: [
            start: [line: 1, character: 1],
            end: [line: 1, character: 4]
          ]
        )

      assert {:ok, doc} =
               Document.Store.get_and_update(uri(), fn document ->
                 Document.apply_content_changes(document, 2, [
                   event
                 ])
               end)

      assert Document.to_string(doc) == "doglo"
      assert {:ok, file} = Document.Store.fetch(uri())
      assert Document.to_string(file) == "doglo"
    end

    test "rejects a change if the version is less than the current version" do
      event = build_change(text: "dog", range: nil)

      assert {:error, :invalid_version} =
               Document.Store.get_and_update(
                 uri(),
                 &Document.apply_content_changes(&1, -1, [event])
               )
    end

    test "a change cannot be applied once a file is closed" do
      event = build_change(text: "dog", range: nil)
      assert :ok = Document.Store.close(uri())

      assert {:error, :not_open} =
               Document.Store.get_and_update(
                 uri(),
                 &Document.apply_content_changes(&1, 3, [event])
               )
    end
  end

  def with_a_temp_document(_) do
    contents = """
    defmodule FakeLines do
    end
    """

    :ok = File.write("/tmp/file.ex", contents)

    on_exit(fn ->
      File.rm!("/tmp/file.ex")
    end)

    {:ok, contents: contents, uri: "file:///tmp/file.ex"}
  end

  describe "a temp document" do
    setup [:with_store, :with_a_temp_document]

    test "can be opened", ctx do
      assert {:ok, doc} = Document.Store.open_temporary(ctx.uri, 100)
      assert Document.to_string(doc) == ctx.contents
    end

    test "is identified as temporary when fetched with its origin", ctx do
      assert {:ok, _doc} = Document.Store.open_temporary(ctx.uri, 100)

      assert {:ok, %Document{version: 0}, :temporary} =
               Document.Store.fetch_with_origin(ctx.uri)
    end

    test "closes after a timeout", ctx do
      assert {:ok, _} = Document.Store.open_temporary(ctx.uri, 100)
      Process.sleep(101)
      refute Document.Store.open?(ctx.uri)
      assert Document.Store.fetch(ctx.uri) == {:error, :not_open}
    end

    test "the extension is extended on subsequent access", ctx do
      assert {:ok, _doc} = Document.Store.open_temporary(ctx.uri, 100)
      Process.sleep(75)
      assert {:ok, _} = Document.Store.open_temporary(ctx.uri, 100)
      Process.sleep(75)
      assert Document.Store.open?(ctx.uri)
      Process.sleep(50)
      refute Document.Store.open?(ctx.uri)
    end

    test "opens permanently when a call to open is made", ctx do
      assert {:ok, _doc} = Document.Store.open_temporary(ctx.uri, 100)
      assert :ok = Document.Store.open(ctx.uri, ctx.contents, 1)
      Process.sleep(120)
      assert Document.Store.open?(ctx.uri)
    end
  end

  describe "derived values" do
    setup context do
      me = self()

      length_fun = fn doc ->
        send(me, :length_called)

        doc
        |> Document.to_string()
        |> String.length()
      end

      :ok = with_store(%{store: [derive: [length: length_fun]]})
      :ok = with_an_open_document(context)
    end

    test "can be fetched with the document by key" do
      assert {:ok, doc, 5} = Document.Store.fetch(uri(), :length)
      assert Document.to_string(doc) == "hello"
    end

    test "can be fetched with a derived value and its origin" do
      assert {:ok, %Document{version: 1}, 5, :open} =
               Document.Store.fetch_with_origin(uri(), :length)
    end

    test "update when the document changes" do
      assert :ok =
               Document.Store.update(uri(), fn document ->
                 Document.apply_content_changes(document, 2, [
                   build_change(text: "dog")
                 ])
               end)

      assert {:ok, doc, 3} = Document.Store.fetch(uri(), :length)
      assert Document.to_string(doc) == "dog"
    end

    test "are lazily computed when first fetched" do
      assert {:ok, %Document{}, 5} = Document.Store.fetch(uri(), :length)
      assert_received :length_called
    end

    test "are only computed again when the document changes" do
      assert {:ok, %Document{}, 5} = Document.Store.fetch(uri(), :length)
      assert_received :length_called

      assert {:ok, %Document{}, 5} = Document.Store.fetch(uri(), :length)
      refute_received :length_called

      assert :ok =
               Document.Store.update(uri(), fn document ->
                 Document.apply_content_changes(document, 2, [
                   build_change(text: "dog")
                 ])
               end)

      assert {:ok, %Document{}, 3} = Document.Store.fetch(uri(), :length)
      assert_received :length_called
    end
  end
end
