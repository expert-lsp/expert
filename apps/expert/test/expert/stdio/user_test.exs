defmodule Expert.Stdio.UserTest do
  use ExUnit.Case, async: false

  # The device is installed by the emulator at boot, so it can only be exercised by
  # booting a child VM with `-user` and reading its real file descriptors.
  @protocol "Content-Length: 2\r\n\r\n{}"

  test "protocol bytes are the only thing on stdout" do
    stdout =
      run("""
      :ok = Expert.Stdio.User.claim()

      IO.puts("ROGUE_io_puts")
      IO.write("ROGUE_io_write")
      IO.inspect(:ROGUE_io_inspect)
      IO.puts(:user, "ROGUE_user")
      IO.puts(:stdio, "ROGUE_stdio")
      IO.puts(:standard_io, "ROGUE_standard_io")
      :io.format("~s~n", ["ROGUE_erlang"])
      dbg("ROGUE_dbg")
      spawn(fn -> IO.puts("ROGUE_spawn") end)
      Task.async(fn -> IO.puts("ROGUE_task") end) |> Task.await()
      require Logger
      Logger.error("ROGUE_logger")
      Process.sleep(100)

      :ok = Expert.Stdio.User.write(#{inspect(@protocol)})
      """)

    assert stdout == @protocol
  end

  test "ordinary IO is forwarded to stderr" do
    merged =
      run(~s|IO.puts("ROGUE_io_puts")\n:io.format("~s~n", ["ROGUE_erlang"])|, stderr: :merge)

    assert merged =~ "ROGUE_io_puts"
    assert merged =~ "ROGUE_erlang"
  end

  test "only the claiming process may write protocol bytes" do
    merged =
      run(
        """
        :ok = Expert.Stdio.User.claim()
        parent = self()
        spawn(fn -> send(parent, {:result, Expert.Stdio.User.write("LEAK")}) end)
        receive do {:result, result} -> IO.puts(:stderr, "result=\#{inspect(result)}") end
        """,
        stderr: :merge
      )

    assert merged =~ "result={:error, :not_owner}"
    refute merged =~ "LEAK"
  end

  test "stdin that arrives before the transport subscribes is replayed" do
    # The port is open from kernel boot; a client may send `initialize` immediately,
    # well before the supervision tree is up.
    stdout =
      run(
        """
        Process.sleep(300)
        :ok = Expert.Stdio.User.claim()
        :ok = Expert.Stdio.User.subscribe()

        receive do
          {:lsp_stdin, bytes} -> Expert.Stdio.User.write(bytes)
        after
          2_000 -> Expert.Stdio.User.write("STDIN_TIMEOUT")
        end
        """,
        stdin: @protocol
      )

    assert stdout == @protocol
  end

  # A dead stdio driver is unrecoverable, so the VM goes down rather than lingering without a
  # transport. It has to stay up long enough to report why, though.
  test "losing the driver shuts the VM down, but reports first" do
    merged =
      run(
        """
        send(:user, {:EXIT, :sys.get_state(:user).port, :simulated_failure})
        Process.sleep(1_500)
        IO.puts(:stderr, "STILL_RUNNING")
        """,
        stderr: :merge
      )

    assert merged =~ "stdio driver terminated (:simulated_failure)"
    refute merged =~ "STILL_RUNNING"
  end

  # `-user` names the module as a string that nothing compiles or type checks, and the release
  # runs it under the `XP` namespace. A rename would silently leave the release booting
  # `user_drv` and sharing stdout again, so pin the two together here.
  test "the release boot flag names the namespaced module" do
    vm_args = __DIR__ |> Path.join("../../../rel/vm.args.eex") |> File.read!()

    assert vm_args =~ "-user Elixir.XP#{inspect(Expert.Stdio.User)}"
  end

  # Debugging a `--port` server or a console needs Erlang's shell, which only exists if
  # `user_drv` owns `:user`. Without the stdio transport we must stay out of the way.
  test "without --stdio, ordinary IO is left on stdout for the shell" do
    stdout = run(~s|IO.puts("ON_STDOUT")|, stdio: false)

    assert stdout =~ "ON_STDOUT"
  end

  defp run(script, opts \\ []) do
    suffix = "#{System.pid()}_#{:erlang.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "stdio_user_#{suffix}.exs")
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    erl_flags =
      [Mix.Project.build_path(), "lib", "*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map_join(" ", &"-pa #{&1}")
      |> Kernel.<>(" -user #{Atom.to_string(Expert.Stdio.User)}")

    # `start/0` only reserves stdout when the stdio transport was asked for, so pass it
    # through the same way the release does.
    args = ["--erl", erl_flags, path] ++ if(opts[:stdio] == false, do: [], else: ["--stdio"])

    port_opts = [:binary, :exit_status]

    port_opts =
      if opts[:stderr] == :merge, do: [:stderr_to_stdout | port_opts], else: port_opts

    port =
      case :os.type() do
        {:win32, _} ->
          command = Enum.map_join([elixir() | args], " ", &~s("#{&1}"))
          Port.open({:spawn, command}, port_opts)

        _ ->
          Port.open({:spawn_executable, elixir()}, [{:args, args} | port_opts])
      end

    if stdin = opts[:stdin], do: Port.command(port, stdin)

    collect(port, "")
  end

  defp elixir, do: System.find_executable("elixir")

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, 0}} -> acc
      {^port, {:exit_status, status}} -> flunk("child exited #{status}, output:\n#{acc}")
    after
      30_000 -> flunk("child timed out, output so far:\n#{acc}")
    end
  end
end
