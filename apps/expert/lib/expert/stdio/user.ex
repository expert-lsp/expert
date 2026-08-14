defmodule Expert.Stdio.User do
  @moduledoc """
  A `:user` device that isolates `:stdio` to GenLSP's Buffer.

  Installed with the `-user` emulator flag in `vm.args.eex` which makes `user_sup` call `start/0`
  rather than Erlang's `user_drv`. We start `user_drv` after registering this process, so OTP still
  owns the platform-specific stdin/stdout handling but sends input here. Ordinary `io_request`s are
  forwarded to `:standard_error`; only protocol writes are sent to `user_drv`.
  """

  use GenServer

  alias Expert.Stdio.User.State

  ## API

  @doc """
  Claims the exclusive right to write protocol bytes. Called by the transport.
  """
  @spec claim() :: :ok | {:error, :already_claimed}
  def claim, do: GenServer.call(:user, :claim)

  @doc """
  Routes stdin to the calling process as `{:lsp_stdin, bytes}` and `:lsp_stdin_eof`.
  """
  @spec subscribe() :: :ok | {:error, :already_subscribed}
  def subscribe, do: GenServer.call(:user, :subscribe)

  @doc """
  Writes an already framed packet to stdout, the only path to file descriptor 1.
  """
  @spec write(iodata()) :: :ok | {:error, term()}
  def write(packet), do: GenServer.call(:user, {:write, packet}, :infinity)

  ## Init

  defp user_drv_options do
    if String.to_integer(System.otp_release()) >= 28 do
      %{initial_shell: :noshell, input: :cooked}
    else
      %{initial_shell: :noshell}
    end
  end

  @doc """
  Entry point for the `-user` boot flag, invoked by `user_sup` rather than directly.
  """
  @spec start() :: pid()
  def start do
    if ~c"--stdio" in :init.get_plain_arguments() do
      {:ok, pid} = GenServer.start_link(__MODULE__, [], name: :user)
      pid
    else
      :user_drv.start()
    end
  end

  @impl GenServer
  def init(_args) do
    Process.flag(:trap_exit, true)
    stderr = Process.whereis(:standard_error) || exit(:standard_error_not_started)
    driver = :user_drv.start(user_drv_options())
    Process.link(driver)
    request_input(driver)

    {:ok, State.new(stderr, driver)}
  end

  ## Callbacks

  @impl GenServer
  def handle_call({:write, packet}, {pid, _tag}, %State{owner: pid} = state) do
    {:reply, write_packet(state.port, packet), state}
  end

  def handle_call({:write, _packet}, _from, %State{} = state) do
    {:reply, {:error, :not_owner}, state}
  end

  def handle_call(:claim, {pid, _tag}, %State{owner: nil} = state) do
    Process.monitor(pid)

    {:reply, :ok, %State{state | owner: pid}}
  end

  def handle_call(:claim, {pid, _tag}, %State{owner: pid} = state) do
    {:reply, :ok, state}
  end

  # Reclaim the lease when the holder is gone but its `:DOWN` has not landed yet. Nothing
  # depends on this today; it only keeps a restarted transport from being locked out.
  def handle_call(:claim, {pid, _tag}, %State{owner: owner} = state) do
    if Process.alive?(owner) do
      {:reply, {:error, :already_claimed}, state}
    else
      Process.monitor(pid)

      {:reply, :ok, %State{state | owner: pid}}
    end
  end

  # stdin starts flowing at kernel boot before the transport is supervised,
  # so anything that arrived in the meantime is replayed here.
  def handle_call(:subscribe, {pid, _tag}, %State{reader: nil} = state) do
    Process.monitor(pid)

    if state.pending != <<>>, do: send(pid, {:lsp_stdin, state.pending})
    if state.eof?, do: send(pid, :lsp_stdin_eof)

    {:reply, :ok, %State{state | reader: pid, pending: <<>>}}
  end

  def handle_call(:subscribe, {pid, _tag}, %State{reader: pid} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:subscribe, {pid, _tag}, %State{reader: reader} = state) do
    if Process.alive?(reader) do
      {:reply, {:error, :already_subscribed}, state}
    else
      Process.monitor(pid)

      {:reply, :ok, %State{state | reader: pid}}
    end
  end

  # noop `:setopts` since we're forwarding to `:standard_error`.
  @impl GenServer
  def handle_info({:io_request, from, reply_as, {:setopts, _opts}}, %State{} = state) do
    io_reply(from, reply_as, :ok)

    {:noreply, state}
  end

  # stdin belongs to the LSP transport, other reads get immediate `:eof`.
  def handle_info({:io_request, from, reply_as, request}, %State{} = state)
      when elem(request, 0) in [:get_chars, :get_line, :get_until, :get_password] do
    io_reply(from, reply_as, :eof)

    {:noreply, state}
  end

  def handle_info({:io_request, from, _reply_as, _request} = request, %State{} = state)
      when is_pid(from) do
    send(state.stderr, request)

    {:noreply, state}
  end

  def handle_info({driver, {:data, bytes}}, %State{port: driver, reader: reader} = state)
      when is_pid(reader) do
    send(reader, {:lsp_stdin, bytes})
    request_input(driver)

    {:noreply, state}
  end

  def handle_info({driver, {:data, bytes}}, %State{port: driver, reader: nil} = state) do
    request_input(driver)

    {:noreply, %State{state | pending: state.pending <> bytes}}
  end

  def handle_info({driver, :eof}, %State{port: driver} = state) do
    if state.reader, do: send(state.reader, :lsp_stdin_eof)

    {:noreply, %State{state | eof?: true}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{owner: pid} = state) do
    {:noreply, %State{state | owner: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{reader: pid} = state) do
    {:noreply, %State{state | reader: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, state}
  end

  # Lost stdio -> Initiate an async shutdown and continue this process so logs can write.
  def handle_info({:EXIT, driver, reason}, %State{port: driver} = state) do
    message = "stdio driver terminated (#{inspect(reason)}), shutting down\n"
    send(state.stderr, {:io_request, self(), make_ref(), {:put_chars, :unicode, message}})

    System.stop()

    {:noreply, state}
  end

  # As `:user` this is the group leader of last resort, so unrecognised messages are routine.
  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp io_reply(from, reply_as, reply), do: send(from, {:io_reply, reply_as, reply})

  defp request_input(driver) do
    if String.to_integer(System.otp_release()) >= 28 do
      send(driver, {self(), :read, 0})
    end
  end

  defp write_packet(driver, packet) do
    reply_as = {self(), make_ref()}
    send(driver, {self(), {:put_chars_sync, :unicode, IO.iodata_to_binary(packet), reply_as}})

    receive do
      {:reply, ^reply_as, reply} ->
        reply

      {:EXIT, ^driver, reason} = exit_message ->
        send(self(), exit_message)
        {:error, reason}
    end
  end
end
