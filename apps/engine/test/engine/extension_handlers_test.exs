defmodule Engine.ExtensionHandlersTest do
  use ExUnit.Case, async: true

  alias Engine.ExtensionHandlers

  defmodule Fixture do
    def complete(request), do: [request]
    def raise_error(_request), do: raise("handler failed")
    def exit_process(_request), do: exit(:handler_exited)
    def sleep(_request), do: Process.sleep(:infinity)

    def wait(test_pid) do
      send(test_pid, {:handler_started, self()})

      receive do
        :continue -> :done
      end
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: ExtensionHandlers.Supervisor})
    :ok
  end

  test "returns the results of the handlers in order" do
    assert [{:ok, [:request]}, {:error, _message}] =
             ExtensionHandlers.call_all([{Fixture, :complete}, {Fixture, :raise_error}], [
               :request
             ])
  end

  test "returns no results without handlers" do
    assert [] = ExtensionHandlers.call_all([], [:request])
  end

  test "returns the exception of a handler that raises" do
    assert [{:error, message}] = ExtensionHandlers.call_all([{Fixture, :raise_error}], [:request])
    assert message =~ "handler failed"
  end

  test "returns the reason of a handler that exits" do
    assert [{:error, message}] =
             ExtensionHandlers.call_all([{Fixture, :exit_process}], [:request])

    assert message =~ "handler_exited"
  end

  test "stops a handler that runs longer than the timeout, and keeps the others" do
    assert [{:error, "timed out after 50 ms"}, {:ok, [:request]}] =
             ExtensionHandlers.call_all([{Fixture, :sleep}, {Fixture, :complete}], [:request], 50)
  end

  test "runs one handler at a time" do
    test_pid = self()

    task =
      Task.async(fn ->
        ExtensionHandlers.call_all([{Fixture, :wait}, {Fixture, :wait}], [test_pid])
      end)

    assert_receive {:handler_started, first_pid}
    refute_receive {:handler_started, _handler_pid}, 50
    send(first_pid, :continue)

    assert_receive {:handler_started, second_pid}
    send(second_pid, :continue)

    assert Task.await(task) == [{:ok, :done}, {:ok, :done}]
  end

  test "returns an error for a module that does not exist" do
    assert [{:error, message}] =
             ExtensionHandlers.call_all([{Engine.ExtensionHandlersTest.Missing, :complete}], [
               :request
             ])

    assert message =~ "Engine.ExtensionHandlersTest.Missing"
  end
end
