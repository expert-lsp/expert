defmodule Engine.Dispatch.PubSub do
  @moduledoc """
  A pubsub event handler for a gen_event controller.
  """
  @behaviour :gen_event

  defmodule State do
    defstruct [:registrations]

    def new do
      %__MODULE__{registrations: %{}}
    end

    def add(%__MODULE__{} = state, message_type, pid) do
      registrations =
        Map.update(state.registrations, message_type, [pid], fn registrations ->
          [pid | registrations]
        end)

      %__MODULE__{state | registrations: registrations}
    end

    def registrations(%__MODULE__{} = state, message_type) do
      all = Map.get(state.registrations, :all, [])
      specific = Map.get(state.registrations, message_type, [])
      all ++ specific
    end

    def registered?(%__MODULE__{} = state, pid) do
      state.registrations
      |> Map.values()
      |> List.flatten()
      |> Enum.member?(pid)
    end

    def remove_all(%__MODULE__{} = state, pid) do
      registrations =
        Map.new(state.registrations, fn {message, pids} ->
          pids = Enum.reject(pids, &(&1 == pid))
          {message, pids}
        end)

      %__MODULE__{state | registrations: registrations}
    end
  end

  def register_message(listener_pid, message_types) do
    {:register, listener_pid, message_types}
  end

  def registered_message(pid) do
    {:registered?, pid}
  end

  @impl :gen_event
  def init(_) do
    {:ok, State.new()}
  end

  @impl :gen_event
  def handle_call({:register, listener_pid, message_types}, %State{} = state) do
    Process.monitor(listener_pid)

    new_state =
      Enum.reduce(message_types, state, fn
        message_type_or_message, %State{} = state ->
          message_type = extract_message_type(message_type_or_message)
          State.add(state, message_type, listener_pid)
      end)

    {:ok, :ok, new_state}
  end

  @impl :gen_event
  def handle_call({:registered?, pid}, %State{} = state) do
    registered? = State.registered?(state, pid)
    {:ok, registered?, state}
  end

  @impl :gen_event
  def handle_info({:DOWN, _ref, _, pid, _}, %State{} = state) do
    new_state = State.remove_all(state, pid)
    {:ok, new_state}
  end

  @impl :gen_event
  def handle_event(message, %State{} = state) do
    message_type = extract_message_type(message)

    state
    |> State.registrations(message_type)
    |> Enum.each(&send(&1, message))

    {:ok, state}
  end

  # Private api

  defp extract_message_type(message_type) when is_atom(message_type), do: message_type
  defp extract_message_type(message_type) when is_tuple(message_type), do: elem(message_type, 0)
end
