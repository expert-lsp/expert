defmodule Expert.EngineApi do
  alias Expert.EngineNode
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.CodeIntelligence
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project

  require Logger

  def call(%Project{} = project, m, f, a \\ []) do
    project
    |> Project.node_name()
    |> :erpc.call(m, f, a)
  end

  def schedule_compile(%Project{} = project, force?) do
    call(project, Engine, :schedule_compile, [force?])
  end

  def clean_and_fetch_deps(%Project{} = project) do
    call(project, Engine, :clean_and_fetch_deps, [])
  end

  def compile_document(%Project{} = project, %Document{} = document) do
    call(project, Engine, :compile_document, [document])
  end

  def expand_alias(
        %Project{} = project,
        segments_or_module,
        %Analysis{} = analysis,
        %Position{} = position
      ) do
    call(project, Engine, :expand_alias, [
      segments_or_module,
      analysis,
      position
    ])
  end

  def list_modules(%Project{} = project) do
    call(project, Engine, :list_modules)
  end

  def project_apps(%Project{} = project) do
    call(project, Engine, :list_apps)
  end

  def format(%Project{} = project, %Document{} = document) do
    call(project, Engine, :format, [document])
  end

  def code_actions(
        %Project{} = project,
        %Document{} = document,
        %Range{} = range,
        diagnostics,
        kinds,
        trigger_kind,
        opts \\ []
      ) do
    call(project, Engine, :code_actions, [
      document,
      range,
      diagnostics,
      kinds,
      trigger_kind,
      opts
    ])
  end

  def resolve_code_action(
        %Project{} = project,
        %Document{} = document,
        %Range{} = range,
        module_name
      ) do
    call(project, Engine, :resolve_code_action, [document, range, module_name])
  end

  def complete(%Project{} = project, %Env{} = env) do
    Logger.info("Completion for #{inspect(env.position)}")
    call(project, Engine, :complete, [env])
  end

  def complete_struct_fields(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    call(project, Engine, :complete_struct_fields, [
      analysis,
      position
    ])
  end

  def declaration(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :declaration, [document, position])
  end

  def definition(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :definition, [document, position])
  end

  def hover(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :hover, [document, position])
  end

  def references(
        %Project{} = project,
        %Analysis{} = analysis,
        %Position{} = position,
        include_definitions?
      ) do
    call(project, Engine, :references, [
      analysis,
      position,
      include_definitions?
    ])
  end

  def modules_with_prefix(%Project{} = project, prefix)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix])
  end

  def modules_with_prefix(%Project{} = project, prefix, predicate)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix, predicate])
  end

  @spec docs(Project.t(), module()) :: {:ok, CodeIntelligence.Docs.t()} | {:error, any()}
  def docs(%Project{} = project, module, opts \\ []) when is_atom(module) do
    call(project, Engine, :docs, [module, opts])
  end

  def register_listener(%Project{} = project, listener_pid, message_types)
      when is_pid(listener_pid) and is_list(message_types) do
    call(project, Engine, :register_listener, [
      listener_pid,
      message_types
    ])
  end

  def broadcast(%Project{} = project, message) do
    call(project, Engine, :broadcast, [message])
  end

  def reindex(%Project{} = project) do
    call(project, Engine, :reindex, [])
  end

  def index_running?(%Project{} = project) do
    call(project, Engine, :index_running?, [])
  end

  def resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    call(project, Engine, :resolve_entity, [analysis, position])
  end

  def struct_definitions(%Project{} = project) do
    call(project, Engine, :struct_definitions, [])
  end

  def document_symbols(%Project{} = project, %Document{} = document) do
    call(project, Engine, :document_symbols, [document])
  end

  def workspace_symbols(%Project{} = project, query) do
    call(project, Engine, :workspace_symbols, [query])
  end

  def runtime_versions(%Project{} = project) do
    call(project, Engine, :runtime_versions, [])
  end

  defdelegate stop(project), to: EngineNode
end
