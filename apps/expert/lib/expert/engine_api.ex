defmodule Expert.EngineApi do
  alias Expert.EngineNode
  alias Forge.Ast
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

  def call(%Project{} = project, m, f, a, timeout) do
    project
    |> Project.node_name()
    |> :erpc.call(m, f, a, timeout)
  end

  @doc "Loads current project code and calls it with a timeout."
  def call_fresh(%Project{} = project, m, f, a, timeout) do
    node = Project.node_name(project)

    case :erpc.call(node, Engine.Module.Loader, :ensure_fresh, [m], timeout) do
      {:module, ^m} ->
        :erpc.call(node, m, f, a, timeout)

      {:error, reason} ->
        raise ArgumentError, "could not load #{inspect(m)}: #{inspect(reason)}"
    end
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

  def analyze(%Project{} = project, %Document{} = document, opts \\ []) do
    call(project, Ast, :analyze, [document, opts])
  end

  @doc """
  Returns cursor analysis with imports from `use` in the project node.

  Reuses the existing AST and import capture. Analyses with captured imports
  return unchanged. A use outside the cursor scope does not require expansion.
  """
  @spec reanalyze_to(Project.t(), Analysis.t(), Position.t()) :: Analysis.t()
  def reanalyze_to(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    analysis = Ast.reanalyze_to(analysis, position)

    unexpanded_use? =
      analysis
      |> Analysis.scopes_at(position)
      |> Enum.any?(fn scope ->
        Enum.any?(scope.uses, fn use ->
          is_nil(use.imported_mfas) and Position.compare(use.range.end, position) in [:lt, :eq]
        end)
      end)

    if unexpanded_use? do
      call(project, Analysis, :new, [Ast.from(analysis), analysis.document, [expand_uses: true]])
    else
      analysis
    end
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

  def implementation(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :implementation, [document, position])
  end

  def hover(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :hover, [document, position])
  end

  def signature_help(%Project{} = project, %Document{} = document, %Position{} = position) do
    call(project, Engine, :signature_help, [document, position])
  end

  def modules_with_prefix(%Project{} = project, prefix)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix])
  end

  def modules_with_prefix(%Project{} = project, prefix, predicate)
      when is_binary(prefix) or is_atom(prefix) do
    call(project, Engine, :modules_with_prefix, [prefix, predicate])
  end

  def module_from_string(%Project{} = project, module_name) when is_binary(module_name) do
    call(project, Engine.Modules, :from_string, [module_name])
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

  def resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    call(project, Engine, :resolve_entity, [analysis, position])
  end

  def application(target, module),
    do: runtime_call(target, Engine.ApplicationCache, :application, [module])

  def available_module?(target, module),
    do: runtime_call(target, Engine.ApplicationCache, :available_module?, [module])

  def clear_application_cache(%Project{} = project),
    do: call(project, Engine.ApplicationCache, :clear, [])

  def resolve_local_call(target, %Analysis{} = analysis, %Position{} = position, name, arity) do
    runtime_call(target, Engine.Analyzer, :resolve_local_call, [analysis, position, name, arity])
  end

  def imports_at(target, %Analysis{} = analysis, %Position{} = position) do
    runtime_call(target, Engine.Analyzer.Imports, :at, [analysis, position])
  end

  def exunit_module?(target, module),
    do: runtime_call(target, Engine.Modules, :exunit_module?, [module])

  def module_exports(target, module),
    do: runtime_call(target, Engine.Modules, :exports, [module])

  @doc "Returns a BEAM path from the project's code path without loading the module."
  @spec beam_path(Project.t() | node(), module()) :: Path.t() | nil
  def beam_path(target, module) do
    case runtime_call(target, :code, :which, [module]) do
      path when is_list(path) -> path |> List.to_string() |> Forge.Path.native()
      unavailable when unavailable in [:non_existing, :preloaded, :cover_compiled] -> nil
    end
  end

  def runtime_versions(%Project{} = project) do
    call(project, Engine, :runtime_versions, [])
  end

  def project_configuration(%Project{} = engine_project, %Project{} = configured_project),
    do: call(engine_project, Engine.Mix, :project_configuration, [configured_project])

  defp runtime_call(%Project{} = project, module, function, arguments),
    do: call(project, module, function, arguments)

  defp runtime_call(node, module, function, arguments) when is_atom(node),
    do: :erpc.call(node, module, function, arguments)

  defdelegate stop(project), to: EngineNode
end
