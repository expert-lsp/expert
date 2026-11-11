defmodule Expert.Test.SemanticMetadataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata
  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Search.Indexer.BeamFile
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Source
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
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
        {:ok, _} = Application.ensure_all_started(:briefly)
        {:ok, root} = Briefly.create(directory: true)
        project = root |> Forge.Document.Path.to_uri() |> Forge.Project.new()
        start_supervised!({Expert.Project.Store, []})

        start_supervised!(
          {Sqlite, [project, runtime_versions: %{erlang: "test-erlang", elixir: "test-elixir"}]}
        )

        start_supervised!({Store, [project, Sqlite]})
        {:ok, supervisor} = ExUnit.fetch_test_supervisor()
        # Delete the directory after the supervised SQLite connection has closed.
        :ok = Briefly.give_away(root, supervisor)
        :ok = Store.enable(project)
        start_supervised!({ModuleRegistry, project})

        patch(EngineApi, :call, fn ^project, Analysis, :cursor_env, arguments ->
          apply(Analysis, :cursor_env, arguments)
        end)

        {:ok, project: project}
      end
    end
  end

  def put_documents(project, documents) do
    module = unique_module("Metadata")

    entries =
      for {document, index} <- Enum.with_index(documents),
          entry <- Indexer.entries("/lib.ex", "#{module}/#{index}", document),
          do: entry

    Store.insert(project, entries)
  end

  def index_source(project, path, source) do
    {:ok, entries} = Source.index(path, source)
    Store.insert(project, entries)
  end

  def compile_metadata!(documents) do
    module = unique_module("Metadata")

    attributes =
      Enum.map_join(documents, "\n", fn document ->
        "@elixir_semantic_metadata #{inspect({@version, document}, limit: :infinity)}"
      end)

    options = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    try do
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
      binary
    after
      Code.compiler_options(options)
    end
  end

  def register_beam!(project, dir, source) do
    {module, beam_path} = compile_beam!(dir, source)
    {:ok, name, exports, _debug_info} = beam_path |> File.read!() |> BeamFile.read()
    :ok = ModuleRegistry.put(project, name, beam_path, nil, exports)
    module
  end

  def compile_beam!(dir, source) do
    path = Path.join(dir, "source.ex")
    File.write!(path, source)
    options = Code.compiler_options()
    Code.compiler_options(docs: true, debug_info: true)

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
    do: project |> env(source, opts) |> SemanticMetadata.complete()

  def hover(project, source, opts \\ []), do: request(:hover, project, source, opts)
  def definition(project, source, opts \\ []), do: request(:definition, project, source, opts)
  def resolve(project, source, opts \\ []), do: request(:resolve, project, source, opts)

  def signature_help(project, source, opts \\ []),
    do: request(:signature_help, project, source, opts)

  def env(project, source, opts \\ []) do
    {position, document} = CursorSupport.pop_cursor(source, Keyword.put_new(opts, :as, :document))
    {:ok, env} = Env.new(project, Ast.analyze(document), position)
    env
  end

  defp request(function, project, source, opts) do
    env = env(project, source, opts)
    cursor = SemanticMetadata.cursor(project, env.analysis, env.position)
    apply(SemanticMetadata, function, [cursor])
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
