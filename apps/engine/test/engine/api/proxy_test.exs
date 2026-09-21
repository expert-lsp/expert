defmodule Engine.Api.ProxyTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Engine.Api.Proxy
  alias Engine.Api.Proxy.BufferingState
  alias Engine.Api.Proxy.DrainingState
  alias Engine.Build
  alias Engine.CodeMod
  alias Engine.Dispatch
  alias Forge.Document
  alias Forge.Document.Changes

  setup do
    start_supervised!(Proxy)
    project = project()
    Engine.set_project(project)

    {:ok, project: project}
  end

  describe "proxy mode" do
    test "proxies broadcasts" do
      patch(Dispatch, :broadcast, :ok)
      assert :ok = Proxy.broadcast(:hello)

      assert_called(Dispatch.broadcast(:hello))
    end

    test "schedule compile is proxied", %{project: project} do
      patch(Build, :schedule_compile, :ok)
      assert :ok = Proxy.schedule_compile(true)
      assert_called(Build.schedule_compile(^project, true))

      assert :ok = Proxy.schedule_compile()
      assert_called(Build.schedule_compile(^project, false))
    end

    test "compile document is proxied", %{project: project} do
      document = %Document{}
      patch(Build, :compile_document, :ok)

      assert :ok = Proxy.compile_document(document)
      assert_called(Build.compile_document(^project, ^document))
    end

    test "formatting is proxied" do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      assert {:ok, %Changes{}} = Proxy.format(document)
      assert_called(CodeMod.Format.edits(^document))
    end
  end

  def with_draining_mode(ctx) do
    patch(Build, :schedule_compile, fn _project, _force? ->
      Process.sleep(100)
      :ok
    end)

    me = self()

    spawn_link(fn ->
      send(me, :ready)
      result = Proxy.schedule_compile()
      send(me, {:proxy_result, result})
    end)

    assert_receive :ready
    Process.sleep(50)

    with_buffer_mode(ctx)
  end

  describe "draining mode" do
    setup [:with_draining_mode]

    test "handles in-flight calls" do
      assert {:draining, %DrainingState{}} = :sys.get_state(Proxy)
      assert_receive {:proxy_result, :ok}
      assert {:buffering, %BufferingState{}} = :sys.get_state(Proxy)
    end

    test "buffers subsequent calls" do
      me = self()
      patch(Dispatch, :broadcast, fn message -> send(me, {:broadcast, message}) end)
      assert :ok = Proxy.broadcast(:hello)
      assert :ok = Proxy.broadcast(:goodbye)

      refute_receive {:broadcast, _}
    end

    test "ends when in-flight requests end", %{stop_buffering: stop_buffering} do
      assert :ok = Proxy.schedule_compile()
      assert_receive {:proxy_result, :ok}
      stop_buffering.()
      assert_called(Build.schedule_compile(_, _))
    end
  end

  def with_buffer_mode(_) do
    buffer_proc =
      spawn_link(fn ->
        receive do
          :continue ->
            :ok
        end
      end)

    Proxy.start_buffering(buffer_proc)

    stop_buffering = fn ->
      send(buffer_proc, :continue)
      Process.sleep(50)
    end

    {:ok, stop_buffering: stop_buffering}
  end

  describe "buffer mode" do
    setup [:with_buffer_mode]

    test "start_buffering can't be called twice" do
      assert {:error, {:already_buffering, _}} = Proxy.start_buffering()
    end

    test "buffers broadcasts" do
      assert :ok = Proxy.broadcast(file_compile_requested())
      refute_any_call(Dispatch.broadcast())
    end

    test "buffers schedule compile" do
      patch(Build, :schedule_compile, :ok)
      assert :ok = Proxy.schedule_compile(true)
      refute_any_call(Build.schedule_compile())

      assert :ok = Proxy.schedule_compile()
      refute_any_call(Build.schedule_compile())
    end

    test "buffers compile document" do
      document = %Document{}
      patch(Build, :compile_document, :ok)

      assert :ok = Proxy.compile_document(document)
      refute_any_call(Build.compile_document())
    end

    test "buffers formatting" do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      assert {:ok, %Changes{}} = Proxy.format(document)
      refute_any_call(CodeMod.Format.edits())
    end
  end

  describe "flushing after buffered mode" do
    setup [:with_buffer_mode]

    test "buffered messages are sent", %{stop_buffering: stop_buffering} do
      patch(Dispatch, :broadcast, :ok)

      Proxy.broadcast(module_updated())
      Proxy.broadcast(project_diagnostics())

      refute_any_call(Dispatch.broadcast())
      stop_buffering.()

      assert_called(Dispatch.broadcast(module_updated()))
      assert_called(Dispatch.broadcast(project_diagnostics()))
    end

    test "formats are dropped", %{stop_buffering: stop_buffering} do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      Proxy.format(document)
      stop_buffering.()
      refute_any_call(CodeMod.Format.edits())
    end

    test "a single compile is scheduled", %{project: project, stop_buffering: stop_buffering} do
      patch(Build, :schedule_compile, :ok)

      Proxy.schedule_compile()
      Proxy.schedule_compile()

      refute_any_call(Build.schedule_compile())

      stop_buffering.()

      assert_called(Build.schedule_compile(^project, _), 1)
    end

    test "document compilations are buffered", %{project: project, stop_buffering: stop_buffering} do
      doc = %Document{}
      patch(Document.Store, :open?, true)
      patch(Build, :compile_document, :ok)

      Proxy.compile_document(doc)
      Proxy.compile_document(doc)

      refute_any_call(Build.compile_document())

      stop_buffering.()

      assert_called(Build.compile_document(^project, ^doc), 1)
    end
  end
end
