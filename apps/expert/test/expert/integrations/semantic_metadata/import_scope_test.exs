defmodule Expert.Integrations.SemanticMetadata.ImportScopeTest do
  use Expert.Test.Expert.CompletionCase
  use Patch

  import Forge.Test.CursorSupport

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Expert.Provider.Handlers.Hover
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias GenLSP.Requests
  alias GenLSP.Structures

  @using_module Module.concat(__MODULE__, EnumUse)
  @documentation "Applies the scoped mapper."

  setup_all %{project: project} do
    start_supervised!(Expert.Application.document_store_child_spec())
    :ok = Expert.Project.Store.add_projects([project])
    true = Expert.Project.Store.transition(project, :ready)

    source = """
    defmodule #{inspect(@using_module)} do
      defmacro __using__(_opts) do
        quote do
          import Enum, only: [map: 2]
        end
      end
    end
    """

    [{@using_module, _beam}] = EngineApi.call(project, Code, :compile_string, [source])
    :ok
  end

  setup %{project: project} do
    [metadata] =
      Decoder.decode(
        elixir_semantic_metadata: [
          {:elixir_semantic_metadata_v1,
           %{
             contexts: [%{mfa: {Enum, :map, 2}, argument: 1, scope: :mapper}],
             scopes: %{
               mapper: %{
                 entries: [
                   %{
                     kind: :function,
                     mfa: {__MODULE__, :scope_value, 0},
                     doc: @documentation
                   }
                 ]
               }
             }
           }}
        ]
      )

    entry = Entry.integration("/metadata.ex", "semantic", :dsl, "Scope", metadata)
    patch(Store, :prefix, fn ^project, _subject, _constraints -> {:ok, [entry]} end)
    patch(EngineApi, :resolve_entity, :error)
    patch(EngineApi, :hover, {:error, :no_doc})
    :ok
  end

  for {directive, declaration} <- [
        import: "import Enum, only: [map: 2]",
        use: "use #{inspect(@using_module)}"
      ],
      location <- [:before, :inside, :sibling] do
    test "#{directive}: semantic completion and hover at #{location}", %{project: project} do
      source = scoped_source(unquote(declaration), unquote(location))
      items = complete(project, source)
      scoped_items = Enum.filter(items, &(&1.label == "scope_value()"))
      hover = hover(project, String.replace(source, "scope_val|", "scope_val|ue()"))

      if unquote(location) == :inside do
        assert [_item] = scoped_items
        assert {:ok, %Structures.Hover{contents: %{value: @documentation}}} = hover
      else
        assert [] = scoped_items
        assert {:ok, nil} = hover
      end

      {position, document} = pop_cursor(source, document: document_path(project))
      analysis = EngineApi.reanalyze_to(project, Ast.analyze(document), position)

      target =
        Analyzer.import_module_for(
          analysis,
          position,
          :map,
          2,
          &ModuleRegistry.module_exports(project, &1)
        )

      expected = if unquote(location) == :inside, do: {:ok, Enum}, else: :error
      assert target == expected
    end
  end

  test "completes a semantic scope in an incomplete call after use", %{project: project} do
    source = """
    defmodule ScopeExample do
      use #{inspect(@using_module)}
      map([], scope_val|
    end
    """

    assert [_item] =
             project
             |> complete(source)
             |> Enum.filter(&(&1.label == "scope_value()"))
  end

  for location <- [:inside, :sibling] do
    test "ordinary completion at #{location} after function-local use", %{project: project} do
      source =
        "use #{inspect(@using_module)}"
        |> scoped_source(unquote(location))
        |> String.replace("map([], scope_val|)", "ma|")

      items = project |> complete(source) |> Enum.filter(&String.starts_with?(&1.label, "map("))

      if unquote(location) == :inside do
        assert [_item] = items
      else
        assert [] = items
      end
    end
  end

  defp scoped_source(declaration, location) do
    """
    defmodule ScopeExample do
      def foo do
        BEFORE_CURSOR
        #{declaration}
        INSIDE_CURSOR
      end

      def bar do
        SIBLING_CURSOR
      end
    end
    """
    |> String.replace(
      "BEFORE_CURSOR",
      if(location == :before, do: "map([], scope_val|)", else: ":ok")
    )
    |> String.replace(
      "INSIDE_CURSOR",
      if(location == :inside, do: "map([], scope_val|)", else: ":ok")
    )
    |> String.replace(
      "SIBLING_CURSOR",
      if(location == :sibling, do: "map([], scope_val|)", else: ":ok")
    )
  end

  defp hover(project, source) do
    {position, document} = pop_cursor(source, document: document_path(project))
    :ok = Document.Store.open(document.uri, Document.to_string(document), 1)

    try do
      request = %Requests.TextDocumentHover{
        id: 1,
        params: %Structures.HoverParams{
          position: position,
          text_document: %Structures.TextDocumentIdentifier{uri: document.uri}
        }
      }

      Hover.handle(request, Context.new(document.uri, document, project))
    after
      Document.Store.close(document.uri)
    end
  end

  defp document_path(project), do: Path.join(Project.root_path(project), "lib/import_scope.ex")
end
