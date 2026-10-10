defmodule Expert.Integrations.SemanticMetadata.HoverTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Expert.Integrations.SemanticMetadata.Hover
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Search.Indexer.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    project = project()
    start_supervised!({Expert.Project.Store, []})
    Expert.Project.Store.set_projects([project])
    Expert.Project.Store.transition(project, :ready)
    start_supervised!({ModuleRegistry, project})

    module = Module.concat(__MODULE__, "Docs#{System.unique_integer([:positive])}")
    path = Path.join(tmp_dir, "docs.ex")
    beam_path = Path.join(tmp_dir, Atom.to_string(module) <> ".beam")
    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    File.write!(path, """
    defmodule #{inspect(module)} do
      @doc "An AND where query expression."
      defmacro where(_query, _bindings, expression), do: expression

      @doc "Takes the first value which is not null."
      def coalesce(left, right), do: left || right
    end
    """)

    assert {:ok, [^module], %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path([path], tmp_dir, return_diagnostics: true)

    :code.purge(module)
    :code.delete(module)
    refute :code.is_loaded(module)

    [document] =
      Decoder.decode(
        elixir_semantic_metadata: [
          {:elixir_semantic_metadata_v1,
           %{
             contexts: [
               %{mfa: {My.Query, :from, 2}, argument: 1, scope: :options}
             ],
             scopes: %{
               options: %{
                 entries: [
                   %{
                     kind: :keyword,
                     name: :where,
                     value_scope: :expressions,
                     doc: {module, :macro, :where, 3}
                   }
                 ]
               },
               expressions: %{
                 entries: [
                   %{
                     kind: :function,
                     mfa: {module, :coalesce, 2},
                     doc: {module, :function, :coalesce, 2}
                   }
                 ]
               }
             }
           }}
        ]
      )

    entry = Entry.integration("/metadata.ex", "semantic", :dsl, "Query", document)
    patch(Store, :prefix, fn ^project, _subject, _constraints -> {:ok, [entry]} end)

    patch(EngineApi, :call, fn ^project, :code, :which, [^module] ->
      String.to_charlist(beam_path)
    end)

    {:ok, project: project, module: module}
  end

  test "reads keyword hover documentation with an empty registry", %{
    project: project,
    module: module
  } do
    assert [{"An AND where query expression.", range}] =
             hover(project, "My.Query.from(u in User, whe|re: coalesce(u.name, \"\"))")

    assert range.start.character == 26
    assert range.end.character == 31
    refute :code.is_loaded(module)
  end

  test "reads expression hover documentation with an empty registry", %{
    project: project,
    module: module
  } do
    assert [{"Takes the first value which is not null.", range}] =
             hover(project, "My.Query.from(u in User, where: coal|esce(u.name, \"\"))")

    assert range.start.character == 33
    assert range.end.character == 41
    refute :code.is_loaded(module)
  end

  defp hover(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    {:ok, env} = Env.new(project, Ast.analyze(document), position)
    Hover.hover(env)
  end
end
