defmodule Project.Server do
  use GenServer

  @impl true
  def init(state), do: {:ok, state}
end
