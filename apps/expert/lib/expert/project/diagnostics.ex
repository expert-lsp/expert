defmodule Expert.Project.Diagnostics do
  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Project.Diagnostics.State
  alias Expert.Project.EngineRuntime
  alias Forge.Ast.Analysis
  alias Forge.Diagnostic
  alias Forge.Document
  alias Forge.Formats
  alias Forge.Project
  alias GenLSP.Notifications.TextDocumentPublishDiagnostics
  alias GenLSP.Structures

  require Logger

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  def register(%Project{} = project) do
    GenServer.call(name(project), :register)
  end

  def publish_parse_diagnostics(%Project{}, uri) do
    with {:ok, %Document{language_id: language_id}, analysis} <-
           Document.Store.fetch(uri, :analysis),
         true <- language_id in ["elixir", "elixir-script"] do
      publish(uri, parse_diagnostics(analysis, uri))
    else
      _ -> :ok
    end
  end

  def clear_file_diagnostics(%Project{}, uri), do: publish(uri, [])

  @impl GenServer
  def init([%Project{} = project]) do
    if EngineRuntime.available?(project), do: register_listener(project)
    {:ok, State.new(project)}
  end

  # GenServer callbacks

  @impl GenServer
  def handle_call(:register, _from, %State{} = state) do
    register_listener(state.project)

    {:reply, :ok, State.reset_build_numbers(state)}
  end

  @impl GenServer
  def handle_info(project_compile_requested(), %State{} = state) do
    state = State.clear_all_flushed(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        project_diagnostics(build_number: build_number, diagnostics: diagnostics),
        %State{} = state
      ) do
    state =
      Enum.reduce(diagnostics, state, fn diagnostic, state ->
        State.add(state, build_number, diagnostic)
      end)

    publish_diagnostics(state)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        file_diagnostics(uri: uri, build_number: build_number, diagnostics: diagnostics),
        %State{} = state
      ) do
    state = State.clear_stale_project_diagnostics(state, uri)

    state =
      case diagnostics do
        [] ->
          State.clear(state, uri)

        diagnostics ->
          Enum.reduce(diagnostics, state, fn diagnostic, state ->
            State.add_file(state, build_number, diagnostic)
          end)
      end

    publish_diagnostics(state)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        project_compiled(elapsed_ms: elapsed_ms),
        %State{} = state
      ) do
    project_name = Project.name(state.project)
    Logger.info("Compiled #{project_name} in #{Formats.time(elapsed_ms, unit: :millisecond)}")

    {:noreply, state}
  end

  # Private

  defp publish_diagnostics(%State{} = state) do
    Enum.each(State.diagnostics_by_uri(state), fn {uri, diagnostics} ->
      with {:ok, diagnostics} <- Expert.Protocol.Convert.to_lsp(diagnostics) do
        GenLSP.notify(Expert.get_lsp(), %TextDocumentPublishDiagnostics{
          params: %Structures.PublishDiagnosticsParams{uri: uri, diagnostics: diagnostics}
        })
      end
    end)
  end

  defp register_listener(project) do
    EngineApi.register_listener(project, self(), [
      file_diagnostics(),
      project_compile_requested(),
      project_compiled(),
      project_diagnostics()
    ])
  end

  defp parse_diagnostics(%Analysis{valid?: true}, _uri), do: []

  defp parse_diagnostics(
         %Analysis{parse_error: {:error, {location, message}, _comments}},
         uri
       ),
       do: [parse_diagnostic(uri, location, message)]

  defp parse_diagnostics(%Analysis{parse_error: {:error, {location, message}}}, uri),
    do: [parse_diagnostic(uri, location, message)]

  defp parse_diagnostic(uri, location, message) do
    position = {Keyword.get(location, :line, 1), Keyword.get(location, :column, 1)}
    Diagnostic.new(uri, position, message, :error, "Elixir")
  end

  defp publish(uri, diagnostics) do
    with {:ok, diagnostics} <- Expert.Protocol.Convert.to_lsp(diagnostics) do
      GenLSP.notify(Expert.get_lsp(), %TextDocumentPublishDiagnostics{
        params: %Structures.PublishDiagnosticsParams{uri: uri, diagnostics: diagnostics}
      })
    end
  end

  def name(%Project{} = project) do
    :"#{Project.unique_name(project)}::diagnostics"
  end
end
