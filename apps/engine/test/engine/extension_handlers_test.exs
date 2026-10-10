defmodule Engine.ExtensionHandlersTest do
  use ExUnit.Case, async: true

  alias Engine.ExtensionHandlers

  defmodule Fixture do
    def complete(request), do: [request]
    def raise_error(_request), do: raise("handler failed")
    def exit_process(_request), do: exit(:handler_exited)
    def sleep(_request), do: Process.sleep(:infinity)
  end

  setup do
    start_supervised!({Task.Supervisor, name: ExtensionHandlers.Supervisor})
    :ok
  end

  test "returns the result of the handler" do
    assert {:ok, [:request]} = ExtensionHandlers.call(Fixture, :complete, [:request], 1_000)
  end

  test "returns the exception of a handler that raises" do
    assert {:error, message} = ExtensionHandlers.call(Fixture, :raise_error, [:request], 1_000)
    assert message =~ "handler failed"
  end

  test "returns the reason of a handler that exits" do
    assert {:error, message} = ExtensionHandlers.call(Fixture, :exit_process, [:request], 1_000)
    assert message =~ "handler_exited"
  end

  test "stops a handler that runs longer than the timeout" do
    assert {:error, "timed out after 50 ms"} =
             ExtensionHandlers.call(Fixture, :sleep, [:request], 50)
  end

  test "returns an error for a module that does not exist" do
    assert {:error, message} =
             ExtensionHandlers.call(
               Engine.ExtensionHandlersTest.Missing,
               :complete,
               [:request],
               1_000
             )

    assert message =~ "Engine.ExtensionHandlersTest.Missing"
  end
end
