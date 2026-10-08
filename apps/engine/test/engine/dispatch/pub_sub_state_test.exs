defmodule Engine.Dispatch.PubSubStateTest do
  use ExUnit.Case

  alias Engine.Dispatch.PubSub.State

  setup do
    state = State.new()
    {:ok, state: state}
  end

  def pid do
    spawn(fn -> :ok end)
  end

  describe "add/3" do
    test "works for a specific type", %{state: state} do
      state = State.add(state, :project_compiled, self())
      assert self() in State.registrations(state, :project_compiled)
      refute self() in State.registrations(state, :other_message)
    end

    test "works for all messages", %{state: state} do
      state = State.add(state, :all, self())
      assert self() in State.registrations(state, :all)
      assert self() in State.registrations(state, :whatever)
    end
  end

  describe "remove_all/2" do
    test "all registrations can be removed", %{state: state} do
      state =
        state
        |> State.add(:all, self())
        |> State.add(:project_compiled, self())
        |> State.add(:other_message, self())
        |> State.add(:yet_another_message, self())
        |> State.remove_all(self())

      refute State.registered?(state, self())
      assert State.registrations(state, :project_compiled) == []
      assert State.registrations(state, :other_message) == []
      assert State.registrations(state, :yet_another_message) == []
    end

    test "preserves other listeners", %{state: state} do
      other_pid = pid()

      state =
        state
        |> State.add(:project_compiled, self())
        |> State.add(:project_compiled, other_pid)
        |> State.add(:all, other_pid)
        |> State.remove_all(self())

      refute State.registered?(state, self())
      assert State.registered?(state, other_pid)
      assert State.registrations(state, :project_compiled) == [other_pid, other_pid]
      assert State.registrations(state, :other_message) == [other_pid]
    end
  end

  describe "registered?/2" do
    test "returns true if a process is registered to all", %{state: state} do
      state = State.add(state, :all, self())
      assert State.registered?(state, self())
    end

    test "returns true if a process is registered to a specific message", %{state: state} do
      state = State.add(state, :project_compiled, self())
      assert State.registered?(state, self())
    end

    test "returns false if a process isn't registered", %{state: state} do
      refute State.registered?(state, self())
    end
  end

  describe "registrations/2" do
    test "can see which things are registered for a given message type", %{state: state} do
      first = pid()
      second = pid()
      third = pid()

      state =
        state
        |> State.add(:project_compiled, first)
        |> State.add(:project_compiled, second)
        |> State.add(:project_compiled, third)

      pids = State.registrations(state, :project_compiled)
      assert first in pids
      assert second in pids
      assert third in pids
    end

    test "includes those pids registered to all", %{state: state} do
      first = pid()
      second = pid()
      third = pid()

      state =
        state
        |> State.add(:project_compiled, first)
        |> State.add(:project_compiled, second)
        |> State.add(:all, third)

      pids = State.registrations(state, :project_compiled)
      assert first in pids
      assert second in pids
      assert third in pids
    end
  end
end
