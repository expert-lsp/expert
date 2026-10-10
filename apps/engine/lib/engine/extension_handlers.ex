defmodule Engine.ExtensionHandlers do
  @moduledoc false

  def call(module, function, arguments, timeout) do
    task = Task.Supervisor.async_nolink(__MODULE__.Supervisor, module, function, arguments)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, Exception.format_exit(reason)}
      nil -> {:error, "timed out after #{timeout} ms"}
    end
  end
end
