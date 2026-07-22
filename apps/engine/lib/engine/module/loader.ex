defmodule Engine.Module.Loader do
  @moduledoc """
  Apparently, Code.ensure_loaded?/1 is pretty slow. I'm guessing because it has to do a
  round trip to the code server for each check. This in turn slows down indexing, so the thought
  is that having a cache will improve performance
  """

  use Agent

  alias Future.Code

  def start_link(_) do
    initialize = fn ->
      Map.new(:code.all_loaded(), fn {name, _} -> {:module, name} end)
    end

    Agent.start_link(initialize, name: __MODULE__)
  end

  def load_all(module_list) do
    loaded_modules =
      case Code.ensure_all_loaded(module_list) do
        :ok ->
          module_list

        {:error, errors} ->
          failed_modules = MapSet.new(errors, &elem(&1, 0))
          Enum.reject(module_list, &MapSet.member?(failed_modules, &1))
      end

    newly_loaded =
      Map.new(loaded_modules, fn module_name -> {module_name, {:module, module_name}} end)

    Agent.update(__MODULE__, fn modules -> Map.merge(modules, newly_loaded) end)
  end

  def ensure_loaded(module_name) do
    Agent.get_and_update(__MODULE__, fn
      %{^module_name => result} = state ->
        {result, state}

      state ->
        result = Code.ensure_loaded(module_name)
        # Note(doorgan): I'm not sure if it's just a timing issue, but on Windows it
        # can sometimes take a little bit before this function returns {:module, name}
        # so I figured not caching the error result here should work. This module is a
        # cache and I think most of the time this is called the module will already
        # have been loaded.
        new_state =
          case result do
            {:module, ^module_name} -> Map.put(state, module_name, result)
            _ -> state
          end

        {result, new_state}
    end)
  end

  def ensure_loaded?(module_name) do
    match?({:module, ^module_name}, ensure_loaded(module_name))
  end

  def forget(module_names) do
    Agent.update(__MODULE__, &Map.drop(&1, module_names))
  end

  def loaded?(module_name) do
    Agent.get(__MODULE__, fn
      %{^module_name => {:module, _}} ->
        true

      _ ->
        false
    end)
  end
end
