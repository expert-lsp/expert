defmodule Forge.Project.Diagnostics.StateTest do
  use ExUnit.Case

  import Forge.Test.Fixtures

  alias Expert.Project.Diagnostics.State
  alias Forge.Diagnostic
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Project

  setup do
    {:ok, _} = start_supervised(Forge.Document.Store)

    project = project()
    state = State.new(project)
    {:ok, project: project(), state: state}
  end

  def existing_file_path do
    Path.join([Project.root_path(project()), "lib", "project.ex"])
  end

  def document(contents, file_path \\ existing_file_path()) do
    file_uri = Document.Path.to_uri(file_path)

    with :ok <- Document.Store.open(file_uri, contents, 0),
         {:ok, document} <- Document.Store.fetch(file_uri) do
      document
    end
  end

  def change_with(document, content) do
    changes = [Edit.new(content)]

    {:ok, document} =
      Document.Store.get_and_update(
        document.uri,
        &Document.apply_content_changes(&1, 2, changes)
      )

    document
  end

  def diagnostic(opts \\ []) do
    file_uri =
      opts
      |> Keyword.get(:file, existing_file_path())
      |> Document.Path.ensure_uri()

    position = Keyword.get(opts, :position, 1)
    message = Keyword.get(opts, :message, "This file is broken")
    severity = Keyword.get(opts, :severity, :error)
    Diagnostic.new(file_uri, position, message, severity, "Elixir")
  end

  describe "add/3" do
    test "allows you to add a diagnostic to a new uri", %{state: state} do
      diagnostic = diagnostic(message: "this code is bad!")

      state = State.add(state, 1, diagnostic)

      assert [%Diagnostic{}] = State.get(state, diagnostic.uri)
    end

    test "allows you to add multiple diagnostics with the same build number", %{state: state} do
      diag_1 = diagnostic(message: "hey!")
      diag_2 = diagnostic(message: "there")

      state =
        state
        |> State.add(1, diag_1)
        |> State.add(1, diag_2)

      assert [^diag_1, ^diag_2] = State.get(state, diag_1.uri)
    end

    test "diagnostics with older build numbers are overwritten", %{state: state} do
      diag_1 = diagnostic(message: "one")
      diag_2 = diagnostic(message: "two")
      diag_3 = diagnostic(message: "three")

      state =
        state
        |> State.add(1, diag_1)
        |> State.add(1, diag_2)
        |> State.add(2, diag_3)

      assert [^diag_3] = State.get(state, diag_3.uri)
    end

    test "duplicate diagnostics are collapsed", %{state: state} do
      diag_1 = diagnostic(message: "dupe")
      diag_2 = diagnostic(message: "two")
      diag_3 = diagnostic(message: "dupe")

      state =
        state
        |> State.add(1, diag_1)
        |> State.add(1, diag_2)
        |> State.add(1, diag_3)

      assert [^diag_1, ^diag_2] = State.get(state, diag_1.uri)
    end
  end

  test "it allows you to add a global diagnostic", %{state: state} do
    diagnostic = diagnostic(message: "This code is awful")

    state = State.add(state, 1, diagnostic)

    assert [%Diagnostic{}] = State.get(state, diagnostic.uri)
  end

  test "accepts new Engine build numbers after registration", %{state: state} do
    old = diagnostic(message: "old Engine")
    new = diagnostic(message: "new Engine")

    state =
      state
      |> State.add_file(10, old)
      |> State.reset_build_numbers()
      |> State.add_file(1, new)

    assert [^new] = State.get(state, new.uri)
  end

  describe "clear_all_flushed/1" do
    test "it should not clear a dirty open file", %{state: state} do
      document =
        "hello"
        |> document()
        |> change_with("hello2")

      state = State.add(state, 1, diagnostic(message: "The code is awful"))

      old_diagnostics = State.get(state, document.uri)
      state = State.clear_all_flushed(state)
      assert ^old_diagnostics = State.get(state, document.uri)
    end

    test "it should not clear a script file even if it is clean", %{
      state: state,
      project: project
    } do
      script_file_path = Path.join([Project.root_path(project), "test", "*.exs"])
      document = document("assert f() == 0", script_file_path)

      state = State.add(state, 1, diagnostic(message: "undefined function f/0"))

      old_diagnostics = State.get(state, document.uri)
      state = State.clear_all_flushed(state)
      assert ^old_diagnostics = State.get(state, document.uri)
    end

    test "it should clear a file's diagnostics if it is just open", %{state: state} do
      document = document("hello")

      state = State.add(state, 1, diagnostic(message: "The code is awful"))

      state = State.clear_all_flushed(state)
      diagnostics = State.get(state, document.uri)

      assert diagnostics == []
    end

    test "it should clear a file's diagnostics if it is closed", %{state: state} do
      document = document("hello")

      state = State.add(state, 1, diagnostic(message: "The code is awful"))

      :ok = Document.Store.close(document.uri)

      state = State.clear_all_flushed(state)
      diagnostics = State.get(state, document.uri)

      assert diagnostics == []
    end
  end
end
