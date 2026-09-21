defmodule Engine.Api.Proxy.BufferingStateStateTest do
  use ExUnit.Case

  import Engine.Api.Proxy.Records
  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Engine.Api.Proxy.BufferingState
  alias Engine.Build
  alias Forge.Document

  setup do
    start_supervised!(Document.Store)
    {:ok, project: project()}
  end

  @default_uri "file:///file.ex"

  def document(uri \\ @default_uri) do
    Document.new(uri, "", 1)
  end

  def open_document(uri \\ @default_uri) do
    :ok = Document.Store.open(uri, "", 1)
    {:ok, document} = Document.Store.fetch(uri)
    document
  end

  def add_to_state_and_flush(messages) do
    messages
    |> Enum.reduce(BufferingState.new(self()), &BufferingState.add_mfa(&2, &1))
    |> BufferingState.flush()
  end

  describe "command collapse" do
    test "multiple project compilations are collapsed", %{project: project} do
      flushed_messages =
        [
          to_mfa(Build.schedule_compile(project)),
          to_mfa(Build.schedule_compile(project))
        ]
        |> add_to_state_and_flush()

      assert [{:mfa, Build, :schedule_compile, [^project], _}] = flushed_messages
    end

    test "force project compilation takes precedence", %{project: project} do
      flushed_messages =
        [
          to_mfa(Build.schedule_compile(project)),
          to_mfa(Build.schedule_compile(project, true)),
          to_mfa(Build.schedule_compile(project))
        ]
        |> add_to_state_and_flush()

      assert [{:mfa, Build, :schedule_compile, [^project, true], _}] = flushed_messages
    end

    test "a project compilation removes all document compilations", %{project: project} do
      flushed_messages =
        [
          to_mfa(Build.compile_document(project, document())),
          to_mfa(Build.schedule_compile(project))
        ]
        |> add_to_state_and_flush()

      assert [{:mfa, Build, :schedule_compile, [^project], _}] = flushed_messages
    end

    test "documents that aren't open are removed", %{project: project} do
      document = document()

      flushed_messages =
        [
          to_mfa(Build.compile_document(project, document))
        ]
        |> add_to_state_and_flush()

      assert Enum.empty?(flushed_messages)
    end

    test "document compiles for a single uri are collapsed", %{project: project} do
      document = open_document()

      flushed_messages =
        [
          to_mfa(Build.compile_document(project, document)),
          to_mfa(Build.compile_document(project, document)),
          to_mfa(Build.compile_document(project, document))
        ]
        |> add_to_state_and_flush()

      assert [{:mfa, Build, :compile_document, [^project, ^document], _}] = flushed_messages
    end
  end

  defp wrap_broadcasts(messages) do
    Enum.map(messages, fn
      mfa() = mfa ->
        mfa

      message ->
        mfa(module: Engine.Dispatch, function: :broadcast, arguments: [message])
    end)
  end

  describe "message collapse" do
    test "document-centric messages are discarded if their document isn't open" do
      flushed_messages =
        [
          filesystem_event(uri: @default_uri),
          file_changed(uri: @default_uri),
          file_compile_requested(uri: @default_uri),
          file_compiled(uri: @default_uri),
          file_deleted(uri: @default_uri)
        ]
        |> wrap_broadcasts()
        |> add_to_state_and_flush()

      assert flushed_messages == []
    end

    test "document-centric messages are kept if their document is open" do
      uri = open_document().uri

      orig_messages =
        [
          filesystem_event(uri: uri),
          file_changed(uri: uri),
          file_compiled(uri: uri),
          file_deleted(uri: uri)
        ]
        |> wrap_broadcasts()

      flushed_messages = add_to_state_and_flush(orig_messages)

      assert flushed_messages == orig_messages
    end

    test "file diagnostics are removed if there's a document compile for that uri", %{
      project: project
    } do
      document = open_document()

      flushed_messages =
        [
          to_mfa(Build.compile_document(project, document)),
          file_diagnostics(uri: @default_uri)
        ]
        |> wrap_broadcasts()
        |> add_to_state_and_flush()

      assert [{:mfa, Build, :compile_document, [^project, ^document], _}] = flushed_messages
    end

    test "file compiles are removed" do
      document = open_document()

      assert [] ==
               [file_compile_requested(uri: document.uri)]
               |> wrap_broadcasts()
               |> add_to_state_and_flush()
    end

    test "project compiles are removed" do
      assert [] ==
               [project_compile_requested()]
               |> wrap_broadcasts()
               |> add_to_state_and_flush()
    end
  end
end
