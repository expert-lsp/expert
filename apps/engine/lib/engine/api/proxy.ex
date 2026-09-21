defmodule Engine.Api.Proxy do
  @moduledoc """
  A bimodal buffering proxy

  This proxy has two modes. In its default mode, it simply forwards function calls to another module, but when
  buffering is activated, it will buffer requests and returned canned responses.
  When a process calls `start_buffering`, it is monitored, and while it's alive, all messages are buffered. When the
  process that calls `start_buffering` exits, the messages that are buffered then have the potential to be emitted.

   Buffered request are subject to the proxy's internal logic. Some requests that are time sensitive
  (like formatting) are dropped. Others are deduplicated, while others are reordered.

  The logic follows below
    `broadcast` - Buffered - Though, those related to other events, like compilation are subject to
                  the rules that govern their source events.
    `schedule_compile` - Buffered - Only one call is kept
    `compile_document` - Buffered, though only one call per URI is kept, and if a `schedule_compile` call
                         was buffered, all `compile_document` calls are dropped
    `format`  - Dropped, as it requires an immediate response. Responds immediately with empty changes

  Internally, there are three states: proxying, draining and buffering.
  The proxy starts in proxying mode. Then, when start_buffering is called, it changes to draining mode. This
  mode checks if there are any in-flight calls. If there aren't any, it changes immediately to buffering mode.
  If there are in-flight requests, it waits for them to finish, and then switches to buffer mode. Once in buffer
  mode, requests are buffered until the process that called `start_buffering` exits. When that happens, then
  the requests are de-duplicated and run, and then the proxy returns to proxying mode.

  """

  @behaviour :gen_statem

  import Engine.Api.Proxy.Records, only: :macros
  import Record

  alias Engine.Api.Proxy.BufferingState
  alias Engine.Api.Proxy.DrainingState
  alias Engine.Api.Proxy.ProxyingState
  alias Engine.CodeMod
  alias Forge.Document
  alias Forge.Document.Changes

  defrecord :buffer, contents: nil, return: :ok
  defrecord :drop, contents: nil, return: :ok

  # public API

  def start_buffering do
    start_buffering(self())
  end

  def start_buffering(caller) when is_pid(caller) do
    :gen_statem.call(__MODULE__, {:start_buffering, caller})
  end

  # proxied functions

  def broadcast(message) do
    mfa = to_mfa(Engine.Dispatch.broadcast(message))
    :gen_statem.call(__MODULE__, buffer(contents: mfa))
  end

  def schedule_compile(force? \\ false) do
    project = Engine.get_project()

    mfa = to_mfa(Engine.Build.schedule_compile(project, force?))
    :gen_statem.call(__MODULE__, buffer(contents: mfa))
  end

  def compile_document(document) do
    project = Engine.get_project()

    mfa = to_mfa(Engine.Build.compile_document(project, document))

    :gen_statem.call(__MODULE__, buffer(contents: mfa))
  end

  def format(%Document{} = document) do
    mfa = to_mfa(CodeMod.Format.edits(document))
    drop = drop(contents: mfa, return: {:ok, Changes.new(document, [])})
    :gen_statem.call(__MODULE__, drop)
  end

  def clean_and_fetch_deps do
    project = Engine.get_project()
    mfa = to_mfa(Engine.Build.clean_and_fetch_deps(project))
    :gen_statem.call(__MODULE__, buffer(contents: mfa))
  end

  # utility functions

  def buffering? do
    :gen_statem.call(__MODULE__, :buffering?)
  end

  # :gen_statem callbacks
  def start_link do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, [], [])
  end

  @impl :gen_statem
  def init(_) do
    {:ok, :proxying, ProxyingState.new()}
  end

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # callbacks for proxying mode

  def proxying({:call, from}, {:start_buffering, caller}, %ProxyingState{} = state) do
    Process.monitor(caller)
    buffering_state = BufferingState.new(caller)

    if ProxyingState.empty?(state) do
      {:next_state, :buffering, buffering_state, {:reply, from, :ok}}
    else
      draining_state = DrainingState.new(buffering_state, state)
      {:next_state, :draining, draining_state, {:reply, from, :ok}}
    end
  end

  def proxying({:call, from}, buffer(contents: contents), %ProxyingState{} = state) do
    state = ProxyingState.apply_mfa(state, from, contents)

    {:keep_state, state}
  end

  def proxying({:call, from}, drop(contents: contents), state) do
    state = ProxyingState.apply_mfa(state, from, contents)
    {:keep_state, state}
  end

  def proxying({:call, from}, :buffering?, state) do
    {:keep_state, state, {:reply, from, false}}
  end

  def proxying(:info, {ref, reply}, %ProxyingState{} = state) when is_reference(ref) do
    ProxyingState.reply(state, ref, reply)
    {:keep_state, state}
  end

  def proxying(:info, {:DOWN, ref, _, _, _}, %ProxyingState{} = state) do
    # Handle the DOWN from the task
    new_state = ProxyingState.consume_reply(state, ref)
    {:keep_state, new_state}
  end

  # Callbacks for the draining mode

  def draining(:info, {ref, reply}, %DrainingState{} = state) when is_reference(ref) do
    DrainingState.reply(state, ref, reply)

    {:keep_state, state}
  end

  def draining({:call, from}, {:start_buffering, _}, %DrainingState{} = state) do
    initiator_pid = state.buffering_state.initiator_pid
    {:keep_state, state, {:reply, from, {:error, {:already_buffering, initiator_pid}}}}
  end

  def draining(
        {:call, from},
        buffer(contents: mfa() = mfa, return: return),
        %DrainingState{} = state
      ) do
    state = DrainingState.add_mfa(state, mfa)
    {:keep_state, state, {:reply, from, return}}
  end

  def draining({:call, from}, drop(return: return), %DrainingState{} = state) do
    {:keep_state, state, {:reply, from, return}}
  end

  def draining({:call, from}, :buffering?, state) do
    {:keep_state, state, {:reply, from, true}}
  end

  def draining(:info, {:DOWN, ref, _, _, _}, %DrainingState{} = state) do
    new_state = DrainingState.consume_reply(state, ref)

    if DrainingState.drained?(new_state) do
      {:next_state, :buffering, state.buffering_state}
    else
      {:keep_state, state}
    end
  end

  # Callbacks for buffering mode

  def buffering({:call, from}, {:start_buffering, _}, %BufferingState{} = state) do
    {:keep_state, state, {:reply, from, {:error, {:already_buffering, state.initiator_pid}}}}
  end

  def buffering(
        {:call, from},
        buffer(contents: mfa() = mfa, return: return),
        %BufferingState{} = state
      ) do
    state = BufferingState.add_mfa(state, mfa)
    {:keep_state, state, {:reply, from, return}}
  end

  def buffering({:call, from}, drop(return: return), %BufferingState{} = state) do
    {:keep_state, state, {:reply, from, return}}
  end

  def buffering(:info, {:DOWN, _, :process, pid, _}, %BufferingState{initiator_pid: pid} = state) do
    state
    |> BufferingState.flush()
    |> Enum.each(&apply/1)

    {:next_state, :proxying, ProxyingState.new()}
  end

  def buffering({:call, from}, :buffering?, state) do
    {:keep_state, state, {:reply, from, true}}
  end

  # Private

  defp apply(mfa(module: module, function: function, arguments: arguments)) do
    apply(module, function, arguments)
  end
end
