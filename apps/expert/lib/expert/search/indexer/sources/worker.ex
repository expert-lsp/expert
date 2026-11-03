defmodule Expert.Search.Indexer.Sources.Worker do
  use GenStage

  def start_link(producer, index) do
    GenStage.start_link(__MODULE__, {producer, index})
  end

  @impl GenStage
  def init({producer, index}) do
    {:producer_consumer, {producer, index}}
  end

  @impl GenStage
  def handle_events(paths, _from, {producer, index}) do
    {:noreply, Enum.map(paths, index), {producer, index}}
  end

  # Stopping right away would drop the paths still queued here.
  @impl GenStage
  def handle_cancel(_reason, {producer, _ref}, {producer, index}) do
    GenStage.async_info(self(), :stop)
    {:noreply, [], {producer, index}}
  end

  def handle_cancel(_reason, _from, state), do: {:stop, :normal, state}

  @impl GenStage
  def handle_info(:stop, state), do: {:stop, :normal, state}
end
