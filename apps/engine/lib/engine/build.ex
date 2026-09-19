defmodule Engine.Build do
  use GenServer

  alias Engine.Build.Document.Compilers.HEEx
  alias Engine.Build.State
  alias Forge.Document
  alias Forge.Project

  require Logger

  # Public interface

  def schedule_compile(%Project{} = _project, force? \\ false) do
    GenServer.cast(__MODULE__, {:compile, force?})
  end

  def compile_document(%Project{} = _project, %Document{} = document) do
    with false <- HEEx.recognizes?(document) do
      GenServer.cast(__MODULE__, {:compile_file, document})
    end

    :ok
  end

  # this is for testing
  def force_compile_document(%Document{} = document) do
    with false <- HEEx.recognizes?(document) do
      GenServer.call(__MODULE__, {:force_compile_file, document})
    end

    :ok
  end

  def clean_and_fetch_deps(%Project{} = project) do
    GenServer.call(__MODULE__, {:clean_and_fetch_deps, project})
  end

  def with_lock(func), do: Engine.with_lock(__MODULE__, func)

  # can't pass work token to Tracer module, so store it in persistent term.

  def set_progress_token(token), do: :persistent_term.put({__MODULE__, :progress_token}, token)

  def get_progress_token, do: :persistent_term.get({__MODULE__, :progress_token}, nil)

  def clear_progress_token, do: :persistent_term.erase({__MODULE__, :progress_token})

  # GenServer Callbacks

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init([]) do
    state = State.new(Engine.get_project())

    with :ok <- State.set_compiler_options() do
      {:ok, state, {:continue, :ensure_build_directory}}
    end
  end

  @impl GenServer
  def handle_continue(:ensure_build_directory, %State{} = state) do
    State.ensure_build_directory(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:force_compile_file, %Document{} = document}, _from, %State{} = state) do
    State.compile_file(state, document)
    {:reply, :ok, state, State.edit_window_millis()}
  end

  @impl GenServer
  def handle_call({:clean_and_fetch_deps, %Project{} = project}, _from, %State{} = state) do
    state = State.fetch_deps(state, project)

    {:reply, State.last_deps_fetch_result(state), state}
  end

  @impl GenServer
  def handle_cast({:compile, force?}, %State{} = state) do
    new_state = State.on_project_compile(state, force?)
    {:noreply, new_state, State.edit_window_millis()}
  end

  @impl GenServer
  def handle_cast({:compile_file, %Document{} = document}, %State{} = state) do
    new_state = State.on_file_compile(state, document)
    {:noreply, new_state, State.edit_window_millis()}
  end

  @impl GenServer
  def handle_info(:timeout, %State{} = state) do
    new_state = State.on_timeout(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(msg, %Project{} = project) do
    Logger.warning("Undefined message: #{inspect(msg)}")
    {:noreply, project}
  end
end
