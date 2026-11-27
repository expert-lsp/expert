defmodule Expert.PortWrapperTest do
  use ExUnit.Case, async: false

  if match?({:win32, _}, :os.type()), do: @moduletag(:skip)

  @wrapper Path.expand("../../priv/port_wrapper.sh", __DIR__)
  @engine ~s(sleep 60 & printf 'ready %s %s\\n' "$$" "$!"; wait)

  test "engine and child exit when the port owner VM is killed" do
    script = """
    [wrapper, engine] = System.argv()
    port = Port.open({:spawn_executable, wrapper}, [:binary, {:args, ["/bin/bash", "-c", engine]}])
    receive do
      {^port, {:data, data}} -> IO.write(data)
    end
    Process.sleep(:infinity)
    """

    manager =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 256},
        {:args, ["-e", script, "--", @wrapper, @engine]}
      ])

    {:os_pid, manager_pid} = Port.info(manager, :os_pid)
    on_exit(fn -> kill(manager_pid) end)

    assert_receive {^manager, {:data, {:eol, "ready " <> pids}}}, 5_000
    [engine_pid, child_pid] = pids |> String.split() |> Enum.map(&String.to_integer/1)
    on_exit(fn -> Enum.each([engine_pid, child_pid], &kill/1) end)

    assert live_count([engine_pid, child_pid]) == 2
    kill(manager_pid)
    assert_receive {^manager, {:exit_status, 137}}, 5_000
    assert await_exit([engine_pid, child_pid], System.monotonic_time(:millisecond) + 3_000)
  end

  test "normal exit preserves output and status" do
    port =
      Port.open({:spawn_executable, @wrapper}, [
        :binary,
        :exit_status,
        {:args, ["/bin/bash", "-c", "printf result; exit 23"]}
      ])

    assert_receive {^port, {:data, "result"}}, 1_000
    assert_receive {^port, {:exit_status, 23}}, 1_000
  end

  defp kill(pid) do
    System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp live_count(pids) do
    {states, _} = System.cmd("ps", ["-o", "stat=", "-p", Enum.join(pids, ",")])
    Enum.count(String.split(states), &(not String.starts_with?(&1, "Z")))
  end

  defp await_exit(pids, deadline) do
    cond do
      live_count(pids) == 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        await_exit(pids, deadline)
    end
  end
end
