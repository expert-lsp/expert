defmodule Expert.Test.SemanticMetadataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Test.CursorSupport

  @version :elixir_semantic_metadata_v1

  using do
    quote do
      use Patch

      import Forge.Test.CursorSupport
      import Forge.Test.Fixtures
      import unquote(__MODULE__)

      setup do
        project = project()
        start_supervised!({Expert.Project.Store, []})
        start_supervised!({ModuleRegistry, project})

        patch(EngineApi, :call, fn ^project, Analysis, :cursor_env, arguments ->
          apply(Analysis, :cursor_env, arguments)
        end)

        {:ok, project: project}
      end
    end
  end

  def put_documents(project, documents) do
    attributes = [elixir_semantic_metadata: Enum.map(documents, &{@version, &1})]
    metadata = %{module: unique_module("Metadata"), attributes: attributes}
    entries = Indexer.index(project, "", metadata, "/lib.ex")

    Patch.patch(Store, :prefix, fn ^project, prefix, _constraints ->
      {:ok, Enum.filter(entries, &String.starts_with?(&1.subject, prefix))}
    end)

    :ok
  end

  def compile_metadata!(documents) do
    module = unique_module("Metadata")

    attributes =
      Enum.map_join(documents, "\n", fn document ->
        "@elixir_semantic_metadata #{inspect({@version, document}, limit: :infinity)}"
      end)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
          accumulate: true,
          persist: true
        )

        #{attributes}
      end
      """)

    unload(module)
    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])
    %{module: module, binary: binary, attributes: attributes}
  end

  def register_beam!(project, dir, source) do
    {module, beam_path} = compile_beam!(dir, source)
    :ok = ModuleRegistry.prune(project, [beam_path])
    module
  end

  def compile_beam!(dir, source) do
    path = Path.join(dir, "source.ex")
    File.write!(path, source)
    options = Code.compiler_options()
    Code.compiler_options(docs: true)

    try do
      {:ok, [module], %{compile_warnings: [], runtime_warnings: []}} =
        Kernel.ParallelCompiler.compile_to_path([path], dir, return_diagnostics: true)

      unload(module)
      {module, Path.join(dir, "#{module}.beam")}
    after
      Code.compiler_options(options)
    end
  end

  def unique_module(name),
    do: Module.concat(__MODULE__, "#{name}#{System.unique_integer([:positive])}")

  def complete(project, source, opts \\ []),
    do: project |> env(source, opts) |> Integrations.complete()

  def hover(project, source, opts \\ []), do: project |> env(source, opts) |> Integrations.hover()

  def definition(project, source, opts \\ []),
    do: project |> env(source, opts) |> Integrations.definition()

  def resolve(project, source, opts \\ []),
    do: project |> env(source, opts) |> Integrations.resolve()

  def signature_help(project, source, opts \\ []),
    do: project |> env(source, opts) |> Integrations.signature_help()

  def env(project, source, opts \\ []) do
    {position, document} = CursorSupport.pop_cursor(source, Keyword.put_new(opts, :as, :document))
    {:ok, env} = Env.new(project, Ast.analyze(document), position)
    cursor_env = EngineApi.cursor_env(project, document, position)
    %Env{env | analysis: %{env.analysis | cursor_env: cursor_env}}
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
