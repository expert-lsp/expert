defmodule Expert.Integrations.SemanticMetadata.HandlersTest do
  use Expert.Test.SemanticMetadataCase, async: false

  import ExUnit.CaptureLog

  alias Expert.CodeIntelligence.Completion
  alias Expert.CodeIntelligence.Hex
  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Handlers
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Completion.Candidate
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Structures.CompletionContext
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList

  describe "completion" do
    test "sends the request of the scope at the cursor", %{project: project} do
      handler = unique_module("Request")

      put_documents(project, [
        query_document(expert: %{facets: %{completion: [{handler, :complete, 1}]}})
      ])

      patch(EngineApi, :call_handler, fn ^project, ^handler, :complete, [request], _timeout ->
        send(self(), {:request, request})
        {:ok, [%{label: "name", kind: :field}]}
      end)

      source = """
      defmodule Example do
        import My.Query, only: [from: 2]
        alias My.Schema, as: Account

        from user in Account, where: user.na|
      end
      """

      assert {:augment, [{%Candidate.Generic{label: "name", kind: :field}, []}], true, []} =
               complete(project, source)

      assert_received {:request,
                       %{
                         aliases: %{[:Account] => My.Schema},
                         call: %{
                           args: [
                             {:in, _, [{:user, _, _}, {:__aliases__, _, [:Account]}]},
                             _options
                           ],
                           target: {My.Query, :from, 2}
                         },
                         hint: "na",
                         module: "Example",
                         semantic: %{scope: :expressions, target: {My.Query, :from, 2}},
                         source: request_source
                       }}

      assert request_source == String.replace(source, "|", "")
    end

    test "runs the handlers of the scope at the cursor only", %{project: project} do
      handler = unique_module("Scoped")

      put_documents(project, [
        query_document(expert: %{facets: %{completion: [{handler, :complete, 1}]}})
      ])

      patch(EngineApi, :call_handler, fn ^project, ^handler, :complete, [_request], _timeout ->
        send(self(), :called)
        {:ok, []}
      end)

      assert :ignore = complete(project, "My.Query.from(user in Account, lock: user.na|")
      refute_received :called
    end

    test "matches the context of a function that an indexed module exports", %{
      project: project
    } do
      handler = unique_module("IndexedExports")
      query = unique_module("IndexedQuery")
      :ok = ModuleRegistry.put(project, query, "/query.beam", :test, [{:"MACRO-from", 3}])

      put_documents(project, [
        [expert: %{facets: %{completion: [{handler, :complete, 1}]}}]
        |> query_document()
        |> put_in([:contexts, Access.at(0), :mfa], {query, :from, 2})
      ])

      patch(EngineApi, :call_handler, {:ok, [%{label: "name", kind: :field}]})

      source = """
      defmodule Example do
        import #{inspect(query)}
        from user in Account, where: user.na|
      end
      """

      assert {:augment, [{%Candidate.Generic{label: "name", kind: :field}, []}], true, []} =
               complete(project, source)

      assert [{"Returns the first non-null value.", _range}] =
               hover(project, String.replace(source, "user.na|", "coal|esce(user.name, 0)"))
    end

    test "puts the piped value first in the call arguments", %{project: project} do
      handler = unique_module("Pipe")

      put_documents(project, [
        %{
          contexts: [%{mfa: {My.Query, :where, 3}, argument: 2, scope: :expression}],
          scopes: %{
            expression: %{
              entries: [],
              data: [expert: %{facets: %{completion: [{handler, :complete, 1}]}}]
            }
          }
        }
      ])

      patch(EngineApi, :call_handler, fn ^project, ^handler, :complete, [request], _timeout ->
        send(self(), {:request, request})
        {:ok, [%{label: "name", kind: :field}]}
      end)

      source = """
      defmodule Example do
        import My.Query, only: [where: 3]
        query |> where([user], user.na|)
      end
      """

      assert {:augment, [{%Candidate.Generic{label: "name"}, []}], true, []} =
               complete(project, source)

      assert_received {:request,
                       %{
                         call: %{
                           args: [
                             {:query, _, _},
                             {:__block__, _, [[{:user, _, _}]]},
                             {:user, _, [{:__cursor__, _, []}]}
                           ]
                         }
                       }}
    end

    test "completes inside a string with the text before the cursor as the hint", %{
      project: project
    } do
      handler = unique_module("String")

      put_documents(project, [
        %{
          contexts: [%{mfa: {My.Events, :subscribe, 1}, argument: 0, scope: :events}],
          scopes: %{
            events: %{
              entries: [],
              data: [expert: %{facets: %{completion: [{handler, :complete, 1}]}}]
            }
          }
        }
      ])

      patch(EngineApi, :call_handler, fn ^project, ^handler, :complete, [request], _timeout ->
        send(self(), {:request, request})
        {:ok, [%{label: "user.created", kind: :value}]}
      end)

      assert {:augment, [{%Candidate.Generic{label: "user.created"}, []}], true, []} =
               complete(project, "My.Events.subscribe(\"user.cr|\")")

      assert_received {:request, %{context: :string, hint: "user.cr"}}
    end

    test "merges the scope entries and the handler items", %{project: project} do
      handler = unique_module("Merge")

      put_documents(project, [
        update_in(
          query_document(expert: %{facets: %{completion: [{handler, :complete, 1}]}}),
          [:scopes, :expressions, :entries],
          fn entries ->
            entries ++ [%{kind: :function, mfa: {My.Query.API, :nullif, 2}}]
          end
        )
      ])

      patch(EngineApi, :call_handler, {:ok, [%{label: "context_name", kind: :field}]})

      assert {:augment,
              [
                {%Candidate.Function{name: "coalesce", arity: 2}, []},
                {%Candidate.Function{name: "nullif", arity: 2}, []},
                {%Candidate.Generic{label: "context_name"}, []}
              ], true, []} = complete(project, "My.Query.from(user in Account, where: |")
    end

    test "keeps the scope entries when a handler returns an empty override", %{
      project: project
    } do
      put_documents(project, [
        query_document(
          expert: %{facets: %{completion: [{unique_module("Override"), :complete, 1}]}}
        )
      ])

      patch(EngineApi, :call_handler, {:ok, %{mode: :override, incomplete?: false, items: []}})

      assert {:override, [{%Candidate.Function{name: "coalesce", arity: 2}, []}], true, []} =
               complete(project, "My.Query.from(user in Account, where: coa|")
    end

    test "combines the items of every completion handler of the scope", %{project: project} do
      first = unique_module("First")
      second = unique_module("Second")
      hover_provider = unique_module("Hover")

      put_documents(project, [
        query_document(
          expert: %{
            facets: %{
              completion: [{first, :complete, 1}, {second, :complete, 1}],
              hover: [{hover_provider, :provide, 1}]
            }
          }
        )
      ])

      patch(EngineApi, :call_handler, fn
        ^project, ^first, :complete, [_request], _timeout ->
          {:ok, [%{label: "first", kind: :field}, %{label: "shared", kind: :field}]}

        ^project, ^second, :complete, [_request], _timeout ->
          {:ok,
           %{
             mode: :override,
             incomplete?: false,
             items: [%{label: "shared", kind: :field}, %{label: "second", kind: :field}]
           }}

        ^project, ^hover_provider, :provide, [_request], _timeout ->
          send(self(), :called_hover_handler)
          {:ok, []}
      end)

      assert {:override,
              [
                {%Candidate.Generic{label: "first"}, []},
                {%Candidate.Generic{label: "shared"}, []},
                {%Candidate.Generic{label: "shared"}, []},
                {%Candidate.Generic{label: "second"}, []}
              ], true, []} = complete(project, "My.Query.from(user in Account, where: value|")

      refute_received :called_hover_handler
    end

    test "ignores a handler that fails", %{project: project} do
      put_documents(project, [
        query_document(
          expert: %{facets: %{completion: [{unique_module("Failure"), :complete, 1}]}}
        )
      ])

      patch(EngineApi, :call_handler, {:error, "handler failed"})

      assert :ignore = complete(project, "My.Query.from(user in Account, where: user.na|")
    end

    test "keeps the items of the other handlers when one fails", %{project: project} do
      failing = unique_module("Failing")
      working = unique_module("Working")

      put_documents(project, [
        query_document(
          expert: %{facets: %{completion: [{failing, :complete, 1}, {working, :complete, 1}]}}
        )
      ])

      patch(EngineApi, :call_handler, fn
        _project, ^failing, :complete, [_request], _timeout ->
          {:error, "timed out after 10000 ms"}

        _project, ^working, :complete, [_request], _timeout ->
          {:ok, [%{label: "name", kind: :field}]}
      end)

      assert {:augment,
              [
                {%Candidate.Function{name: "coalesce"}, []},
                {%Candidate.Generic{label: "name"}, []}
              ], true, []} =
               complete(project, "My.Query.from(user in Account, where: |")
    end

    test "keeps the first 500 handler items", %{project: project} do
      put_documents(project, [
        query_document(expert: %{facets: %{completion: [{unique_module("Limit"), :complete, 1}]}})
      ])

      patch(
        EngineApi,
        :call_handler,
        {:ok, for(index <- 0..500, do: %{label: "item-#{index}", kind: :value})}
      )

      assert {:augment, items, true, []} =
               complete(project, "My.Query.from(user in Account, where: user.na|")

      assert Enum.map(items, fn {item, []} -> item.label end) ==
               for(index <- 0..499, do: "item-#{index}")
    end

    test "ignores and logs the result of a handler that returns an invalid item", %{
      project: project
    } do
      Logger.put_module_level(Handlers, :warning)
      on_exit(fn -> Logger.put_module_level(Handlers, Logger.level()) end)
      handler = unique_module("Invalid")

      put_documents(project, [
        query_document(expert: %{facets: %{completion: [{handler, :complete, 1}]}})
      ])

      patch(EngineApi, :call_handler, {:ok, [%{label: "name", kind: :field}, %{label: :invalid}]})

      assert {:ignore, log} =
               with_log(fn ->
                 complete(project, "My.Query.from(user in Account, where: user.na|")
               end)

      assert log =~ "Handler completion returned an invalid result handler=#{inspect(handler)}"
    end
  end

  describe "hover" do
    test "lists handler hovers before the entry documentation", %{project: project} do
      first = unique_module("HoverFirst")
      second = unique_module("HoverSecond")

      put_documents(project, [
        query_document(expert: %{facets: %{hover: [{first, :hover, 1}, {second, :hover, 1}]}})
      ])

      patch(EngineApi, :call_handler, fn
        ^project, ^first, :hover, [request], _timeout ->
          send(self(), {:request, request})
          {:ok, "First hover"}

        ^project, ^second, :hover, [_request], _timeout ->
          {:ok, nil}
      end)

      source = "My.Query.from(user in Account, where: coal|esce(user.name, 0))"

      assert [{"First hover", range}, {"Returns the first non-null value.", range}] =
               hover(project, source)

      assert_received {:request,
                       %{
                         identifier: "coalesce",
                         range: %{
                           start: %{line: 1, character: 39},
                           end: %{line: 1, character: 47}
                         },
                         semantic: %{scope: :expressions}
                       }}
    end
  end

  describe "hover where Elixir reads no identifier" do
    test "sends no identifier and takes the range of the handler", %{project: project} do
      put_documents(project, [sigil_document(hover: [{SigilHandler, :hover, 1}])])

      patch(EngineApi, :call_handler, fn _project, SigilHandler, :hover, [request], _timeout ->
        send(self(), {:request, request})
        range = %{start: %{line: 3, character: 10}, end: %{line: 3, character: 16}}
        {:ok, %{contents: "Renders a button.", range: range}}
      end)

      source = ~S'''
      defmodule MyWeb.Page do
        def render(assigns) do
          ~H"<.but|ton />"
        end
      end
      '''

      assert [{"Renders a button.", range}] = hover(project, source)
      assert {range.start.line, range.start.character} == {3, 10}
      assert {range.end.line, range.end.character} == {3, 16}
      assert_received {:request, %{identifier: nil, range: nil}}
    end
  end

  describe "definition" do
    setup do
      start_supervised!(Expert.Application.document_store_child_spec())
      :ok
    end

    @tag :tmp_dir
    test "returns the locations that handlers give", %{project: project, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "components.ex")
      File.write!(path, "defmodule Components do\n  def button(assigns), do: assigns\nend\n")
      put_documents(project, [sigil_document(definition: [{SigilHandler, :definition, 1}])])

      range = %{start: %{line: 2, character: 3}, end: %{line: 2, character: 3}}

      patch(
        EngineApi,
        :call_handler,
        {:ok, [%{path: path, range: range}]}
      )

      source = ~S'''
      defmodule MyWeb.Page do
        def render(assigns) do
          ~H"<.but|ton />"
        end
      end
      '''

      assert [%Location{range: range} = location] = definition(project, source)
      assert Location.uri(location) == Document.Path.ensure_uri(path)
      assert {range.start.line, range.start.character} == {2, 3}
    end
  end

  describe "resolve" do
    @source ~S'''
    defmodule MyWeb.Page do
      def render(assigns) do
        ~H"<p>{forma|t(@date)}</p>"
      end
    end
    '''

    setup %{project: project} do
      put_documents(project, [sigil_document(resolve: [{SigilHandler, :resolve, 1}])])
      :ok
    end

    test "returns the entity of a handler with its range", %{project: project} do
      range = %{start: %{line: 3, character: 12}, end: %{line: 3, character: 18}}
      entity = %{kind: :function, module: MyWeb.Helpers, name: :format, arity: 1}
      patch(EngineApi, :call_handler, {:ok, %{entity: entity, range: range}})

      assert {:entity, ^entity, resolved_range} = resolve(project, @source)
      assert {resolved_range.start.character, resolved_range.end.character} == {12, 18}
    end

    test "returns the delegation of a handler", %{project: project} do
      patch(EngineApi, :call_handler, {:ok, %{delegate: %{source: "format(@date)"}}})

      assert {:delegate, %{source: "format(@date)"}} = resolve(project, @source)
    end

    test "ignores an entity outside the spec", %{project: project} do
      patch(EngineApi, :call_handler, {:ok, %{entity: {:call, MyWeb.Helpers, :format, 1}}})

      assert :ignore = resolve(project, @source)
    end
  end

  describe "references" do
    setup do
      start_supervised!(Expert.Application.document_store_child_spec())
      :ok
    end

    @tag :tmp_dir
    test "sends the calls of the contexts of the document, by file, to its handlers", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "router.ex")
      source = ~s(get "/", PageController, :index\nget "/a", PageController, :show\n)
      File.write!(path, source)
      handler = unique_module("References")
      put_documents(project, [references_document(handler)])
      document = Document.new(Document.Path.ensure_uri(path), source, 1)

      calls =
        for line <- [2, 1] do
          start = Position.new(document, line, 1)
          range = Range.new(start, Position.new(document, line, 4))
          Entry.reference(path, Block.root(), "My.Router.get/3", {:function, :usage}, range, :app)
        end

      patch(Store, :exact_many, fn ^project, ["My.Router.get/3"], [subtype: :reference] ->
        {:ok, calls}
      end)

      patch(EngineApi, :call_handler, fn ^project, ^handler, :references, [request], _timeout ->
        send(self(), {:request, request})
        range = %{start: %{line: 1, character: 10}, end: %{line: 1, character: 24}}
        {:ok, [%{path: path, range: range}]}
      end)

      assert [%Location{range: range} = location] =
               Integrations.references(project, {:module, MyWeb.PageController})

      assert Location.uri(location) == document.uri
      assert {range.start.character, range.end.character} == {10, 24}

      call = &%{position: %{line: &1, character: 1}, target: {My.Router, :get, 3}}

      assert_received {:request,
                       %{
                         entity: %{kind: :module, module: MyWeb.PageController},
                         files: [%{path: request_path, calls: calls}]
                       }}

      assert Forge.Path.normalize(request_path) == Forge.Path.normalize(path)

      assert calls == [call.(1), call.(2)]
    end

    test "calls no handler when no file calls the functions of its contexts", %{
      project: project
    } do
      put_documents(project, [references_document(unique_module("Unused"))])
      patch(Store, :exact_many, {:ok, []})

      patch(EngineApi, :call_handler, fn _project, _module, _function, _arguments, _timeout ->
        flunk("called")
      end)

      assert [] = Integrations.references(project, {:module, MyWeb.Page})
    end

    test "calls no handler without a document that registers one", %{project: project} do
      put_documents(project, [sigil_document(resolve: [{SigilHandler, :resolve, 1}])])

      patch(EngineApi, :call_handler, fn _project, _module, _function, _arguments, _timeout ->
        flunk("called")
      end)

      assert [] = Integrations.references(project, {:module, MyWeb.Page})
    end

    test "sends a call as a macro when its module exports that macro", %{project: project} do
      handler = unique_module("MacroReferences")
      module = unique_module("Router")
      :ok = ModuleRegistry.put(project, module, "/router.beam", :test, [{:"MACRO-get", 4}])
      put_documents(project, [references_document(handler)])
      document = Document.new("file:///router.ex", "get \"/\", PageController, :index\n", 1)
      range = Range.new(Position.new(document, 1, 1), Position.new(document, 1, 4))

      call =
        Entry.reference(
          "/router.ex",
          Block.root(),
          "My.Router.get/3",
          {:function, :usage},
          range,
          :app
        )

      patch(Store, :exact_many, {:ok, [call]})

      patch(EngineApi, :call_handler, fn ^project, ^handler, :references, [request], _timeout ->
        send(self(), {:entity, request.entity})
        {:ok, []}
      end)

      Integrations.references(project, {:call, module, :get, 3})
      Integrations.references(project, {:call, module, :get, 4})

      assert_received {:entity, %{kind: :macro, module: ^module, name: :get, arity: 3}}
      assert_received {:entity, %{kind: :function, module: ^module, name: :get, arity: 4}}
    end
  end

  describe "signature help" do
    test "returns the signatures of every handler of the scope", %{project: project} do
      first = unique_module("SignatureFirst")
      second = unique_module("SignatureSecond")

      put_documents(project, [
        query_document(
          expert: %{
            facets: %{signature_help: [{first, :signatures, 1}, {second, :signatures, 1}]}
          }
        )
      ])

      patch(EngineApi, :call_handler, fn
        ^project, ^first, :signatures, [request], _timeout ->
          send(self(), {:request, request})

          {:ok,
           [
             %{
               label: "coalesce(value, fallback)",
               parameters: ["value", "fallback"],
               doc: "Docs",
               active_parameter: 1
             }
           ]}

        ^project, ^second, :signatures, [_request], _timeout ->
          {:ok, [%{label: "nullif(left, right)", parameters: ["left", "right"]}]}
      end)

      assert [
               %{
                 label: "coalesce(value, fallback)",
                 parameters: ["value", "fallback"],
                 doc: "Docs",
                 active_parameter: 1
               },
               %{
                 label: "nullif(left, right)",
                 parameters: ["left", "right"],
                 doc: nil,
                 active_parameter: nil
               }
             ] =
               signature_help(
                 project,
                 "My.Query.from(user in Account, where: coalesce(user.name, |"
               )

      assert_received {:request, %{semantic: %{scope: :expressions}} = request}
      refute Map.has_key?(request, :active_argument)
    end

    test "ignores the result of a handler whose active parameter is not a parameter", %{
      project: project
    } do
      handler = unique_module("SignatureActive")

      put_documents(project, [
        query_document(expert: %{facets: %{signature_help: [{handler, :signatures, 1}]}})
      ])

      patch(EngineApi, :call_handler, fn _project, ^handler, :signatures, [_request], _ ->
        {:ok, [%{label: "coalesce(value)", parameters: ["value"], active_parameter: 1}]}
      end)

      assert :ignore = signature_help(project, "My.Query.from(user in Account, where: coalesce(|")
    end
  end

  describe "completion through Expert" do
    setup do
      patch(EngineApi, :complete, [])
      patch(EngineApi, :project_apps, [])
      patch(Store, :exact_many, {:ok, []})
      patch(Hex, :project_file?, false)
      :ok
    end

    test "sends the imports at the cursor to a sigil handler", %{project: project} do
      put_documents(project, [sigil_document(SigilHandler)])

      patch(EngineApi, :call_handler, fn _project, SigilHandler, :complete, [request], _ ->
        send(self(), {:request, request})

        {:ok,
         %{mode: :override, incomplete?: false, items: [%{label: "button", kind: :function}]}}
      end)

      source = ~S'''
      defmodule MyWeb.Page do
        import Enum, only: [map: 2]

        def render(assigns) do
          ~H"<.bu|"
        end
      end
      '''

      assert [%CompletionItem{label: "button"}] =
               complete_document(project, source, "lib/page.ex")

      assert_received {:request, %{imports: imports}}
      assert {Enum, :map, 2} in imports
    end

    test "follows a handler delegation only once", %{project: project} do
      handler = unique_module("Delegating")

      put_documents(project, [language_document("elixir", handler)])

      patch(EngineApi, :call_handler, fn _project, ^handler, :complete, [request], _timeout ->
        send(self(), :called)
        {:ok, %{delegate: %{source: request.source}}}
      end)

      complete_document(project, "foo|", "lib/delegating.ex")

      assert_received :called
      assert_received :called
      refute_received :called
    end

    test "completes a delegated source and edits the original document", %{project: project} do
      put_documents(project, [
        language_document("eex", unique_module("Template")),
        query_document([])
      ])

      patch(
        EngineApi,
        :call_handler,
        {:ok,
         %{
           delegate: %{
             source:
               "   import My.Query, only: [from: 2] ; \n    from user in User, where: coal ; "
           }
         }}
      )

      source = "<% import My.Query, only: [from: 2] %>\n<%= from user in User, where: coal| %>"

      assert %CompletionList{
               items: [
                 %CompletionItem{
                   label: "coalesce(arg1, arg2)",
                   documentation: %{value: "Returns the first non-null value."},
                   text_edit: %Document.Changes{document: %Document{uri: "file:///lib/query.eex"}}
                 }
               ],
               is_incomplete: true
             } = complete_document(project, source, "lib/query.eex")
    end

    test "returns no items where a handler overrides completion with no items", %{
      project: project
    } do
      put_documents(project, [language_document("eex", unique_module("Template"))])
      patch(EngineApi, :complete, [%Candidate.Generic{label: "ordinary"}])
      patch(EngineApi, :call_handler, {:ok, %{mode: :override, incomplete?: false, items: []}})

      assert %CompletionList{items: []} = complete_document(project, "text|", "lib/query.eex")
    end

    test "replaces the range that a handler item gives", %{project: project} do
      {position, result} =
        complete_tag_name(project, fn %{position: %{line: line, character: character}} ->
          range = %{
            start: %{line: line, character: character - 2},
            end: %{line: line, character: character}
          }

          [%{label: "button", kind: :function, range: range}]
        end)

      assert [%CompletionItem{label: "button", text_edit: changes}] = result
      assert %Document.Changes{edits: %Document.Edit{text: "button", range: range}} = changes
      assert {range.start.line, range.start.character} == {position.line, position.character - 2}
      assert {range.end.line, range.end.character} == {position.line, position.character}
    end

    test "inserts an item at the cursor when its range is on another line", %{project: project} do
      {position, result} =
        complete_tag_name(project, fn %{position: %{line: line}} ->
          range = %{start: %{line: line - 1, character: 1}, end: %{line: line - 1, character: 3}}
          [%{label: "button", kind: :function, range: range}]
        end)

      assert [%CompletionItem{text_edit: %Document.Changes{edits: %Document.Edit{range: range}}}] =
               result

      assert {range.start.line, range.start.character} == {position.line, position.character}
      assert {range.end.line, range.end.character} == {position.line, position.character}
    end

    test "ignores the result of a handler whose item range spans lines", %{project: project} do
      {_position, result} =
        complete_tag_name(project, fn %{position: %{line: line}} ->
          range = %{start: %{line: line, character: 1}, end: %{line: line + 1, character: 1}}
          [%{label: "button", kind: :function, range: range}]
        end)

      assert %CompletionList{items: []} = result
    end
  end

  defp complete_tag_name(project, items_for) do
    put_documents(project, [sigil_document(SigilHandler)])

    patch(EngineApi, :call_handler, fn _project, SigilHandler, :complete, [request], _timeout ->
      {:ok, %{mode: :override, incomplete?: false, items: items_for.(request)}}
    end)

    source = ~S'''
    defmodule MyWeb.Page do
      def render(assigns) do
        ~H"<.bu|"
      end
    end
    '''

    {position, _document} = pop_cursor(source, as: :document)
    {position, complete_document(project, source, "lib/page.ex")}
  end

  defp complete_document(project, source, path) do
    {position, document} = pop_cursor(source, document: "file:///" <> path)

    Completion.complete(
      project,
      Ast.analyze(document),
      position,
      %CompletionContext{trigger_kind: CompletionTriggerKind.invoked()}
    )
  end

  defp language_document(language_id, handler) do
    %{
      contexts: [%{language_id: language_id, scope: :document}],
      scopes: %{
        document: %{
          entries: [],
          data: [expert: %{facets: %{completion: [{handler, :complete, 1}]}}]
        }
      }
    }
  end

  defp sigil_document(facets) when is_list(facets) do
    %{
      contexts: [%{sigil: "H", scope: :markup}],
      scopes: %{markup: %{entries: [], data: [expert: %{facets: Map.new(facets)}]}}
    }
  end

  defp sigil_document(handler), do: sigil_document(completion: [{handler, :complete, 1}])

  defp references_document(handler) do
    %{
      contexts: [%{mfa: {My.Router, :get, 3}, argument: 1, scope: :controllers}],
      scopes: %{controllers: %{entries: []}},
      data: [expert: %{facets: %{references: [{handler, :references, 1}]}}]
    }
  end

  defp query_document(data) do
    %{
      contexts: [%{mfa: {My.Query, :from, 2}, argument: 1, scope: :query_options}],
      scopes: %{
        query_options: %{
          entries: [%{kind: :keyword, name: :where, value_scope: :expressions}]
        },
        expressions: %{
          entries: [
            %{
              kind: :function,
              mfa: {My.Query.API, :coalesce, 2},
              doc: "Returns the first non-null value."
            }
          ],
          data: data
        }
      }
    }
  end
end
