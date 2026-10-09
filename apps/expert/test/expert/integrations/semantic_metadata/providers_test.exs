defmodule Expert.Integrations.SemanticMetadata.ProvidersTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Completion
  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Expert.Integrations.SemanticMetadata.Hover
  alias Expert.Integrations.SemanticMetadata.SignatureHelp
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  test "preserves consumer data as part of a semantic scope" do
    provider = unique_module("Decoder")
    document = query_document(provider)

    assert [
             %{
               scopes: %{
                 expressions: %{
                   data: [
                     expert: %{
                       facets: %{completion: [{^provider, :complete, 1}]}
                     }
                   ],
                   entries: [%{kind: :function}]
                 }
               }
             }
           ] = decode([document])

    repeated =
      get_in(document, [:scopes, :expressions, :data]) ++
        [expert: %{future: true}, other: %{value: 1}]

    assert [%{scopes: %{expressions: %{data: ^repeated}}}] =
             document
             |> put_in([:scopes, :expressions, :data], repeated)
             |> then(&decode([&1]))
  end

  @tag :tmp_dir
  test "indexes a provider with its semantic document without loading the provider", %{
    tmp_dir: tmp_dir
  } do
    provider = unique_module("IndexerProvider")
    owner = unique_module("IndexerOwner")
    document = query_document(provider)
    attribute = inspect({:elixir_semantic_metadata_v1, document}, limit: :infinity)

    [{^provider, _provider_binary}] =
      Code.compile_string("""
      defmodule #{inspect(provider)} do
        def complete(_request), do: []
      end
      """)

    [{^owner, owner_binary}] =
      Code.compile_string("""
      defmodule #{inspect(owner)} do
        Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
          accumulate: true,
          persist: true
        )

        @elixir_semantic_metadata #{attribute}
      end
      """)

    :code.purge(provider)
    :code.delete(provider)
    refute :code.is_loaded(provider)

    {:ok, {^owner, [attributes: attributes]}} =
      :beam_lib.chunks(owner_binary, [:attributes])

    assert [
             %Entry{
               metadata: %{
                 payload: %{
                   scopes: %{
                     expressions: %{
                       data: [
                         expert: %{
                           facets: %{completion: [{^provider, :complete, 1}]}
                         }
                       ]
                     }
                   }
                 }
               }
             }
           ] =
             Integrations.index_beam(
               project(),
               owner_binary,
               %{module: owner, attributes: attributes},
               Path.join(tmp_dir, "owner.ex")
             )

    refute :code.is_loaded(provider)
  end

  test "invokes a provider only after the final semantic scope selects it" do
    project = project()
    provider = unique_module("FinalScope")
    test_pid = self()
    put_documents(project, [query_document(provider)])

    patch(EngineApi, :call_fresh, fn ^project, ^provider, :complete, [request], 10_000 ->
      send(test_pid, {:provider_request, request})
      [%{label: "name", insert_text: "name", kind: :field}]
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

    assert_receive {:provider_request,
                    %{
                      aliases: %{[:Account] => My.Schema},
                      call: %{
                        args: [
                          {:in, _, [{:user, _, _}, {:__aliases__, _, [:Account]}]},
                          _options
                        ],
                        target: %{module: "Elixir.My.Query", name: "from", arity: 2}
                      },
                      hint: "na",
                      module: "Example",
                      semantic: %{
                        scope: :expressions,
                        target: %{module: "Elixir.My.Query", name: "from", arity: 2}
                      },
                      source: request_source
                    }}

    assert request_source == String.replace(source, "|", "")

    assert :ignore = complete(project, "My.Query.from(user in Account, lock: user.na|")
    refute_receive {:provider_request, _request}
  end

  test "resolves explicit imports from indexed BEAM exports" do
    project = project()
    provider = unique_module("IndexedExports")
    query = unique_module("IndexedQuery")
    start_supervised!({ModuleRegistry, project})
    :ok = ModuleRegistry.put(project, query, "/query.beam", :test, [{:"MACRO-from", 3}])

    document =
      provider
      |> query_document()
      |> put_in([:contexts, Access.at(0), :mfa], {query, :from, 2})

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn ^project, ^provider, :complete, [_request], 10_000 ->
      [%{label: "name", kind: :field}]
    end)

    source = """
    defmodule Example do
      import #{inspect(query)}
      from user in Account, where: user.na|
    end
    """

    assert {:augment, [{%Candidate.Generic{label: "name", kind: :field}, []}], true, []} =
             complete(project, source)

    hover_source = String.replace(source, "user.na|", "coal|esce(user.name, 0)")

    assert [{"Returns the first non-null value.", _range}] = hover(project, hover_source)
  end

  test "includes the pipe input in a provider request" do
    project = project()
    provider = unique_module("Pipe")
    test_pid = self()

    document = %{
      contexts: [
        %{
          mfa: {My.Query, :where, 3},
          argument: 2,
          scope: :expression
        }
      ],
      scopes: %{
        expression: %{entries: [], data: [expert: provider_data(provider)]}
      }
    }

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn ^project, ^provider, :complete, [request], 10_000 ->
      send(test_pid, {:pipe_request, request})
      [%{label: "name", kind: :field}]
    end)

    source = """
    defmodule Example do
      import My.Query, only: [where: 3]
      query |> where([user], user.na|)
    end
    """

    assert match?(
             {:augment, [{%Candidate.Generic{label: "name"}, []}], true, []},
             complete(project, source)
           )

    assert_receive {:pipe_request,
                    %{
                      call: %{
                        args: [
                          {:query, _, _},
                          [{:user, _, _}],
                          {:user, _, [{:__cursor__, _, _}]}
                        ]
                      }
                    }}
  end

  test "runs a selected provider inside a string" do
    project = project()
    provider = unique_module("String")
    test_pid = self()

    document = %{
      contexts: [
        %{
          mfa: {My.Events, :subscribe, 1},
          argument: 0,
          scope: :events
        }
      ],
      scopes: %{events: %{entries: [], data: [expert: provider_data(provider)]}}
    }

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn ^project, ^provider, :complete, [request], 10_000 ->
      send(test_pid, {:string_request, request})
      [%{label: "user.created", kind: :value}]
    end)

    assert {:augment, [{%Candidate.Generic{label: "user.created"}, []}], true, []} =
             complete(project, "My.Events.subscribe(\"user.cr|\")")

    assert_receive {:string_request, %{context: :string, hint: "user.cr"}}
  end

  test "merges provider and static candidates from one resolved scope" do
    project = project()
    provider = unique_module("Merge")

    document =
      update_in(query_document(provider), [:scopes, :expressions, :entries], fn candidates ->
        candidates ++ [%{kind: :function, mfa: {My.Query.API, :nullif, 2}}]
      end)

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, [%{label: "context_name", kind: :field}])

    assert {:augment,
            [
              {%Candidate.Function{name: "coalesce", arity: 2}, []},
              {%Candidate.Function{name: "nullif", arity: 2}, []},
              {%Candidate.Generic{label: "context_name"}, []}
            ], true, []} =
             complete(project, "My.Query.from(user in Account, where: |")
  end

  test "keeps static candidates when a provider returns an empty override" do
    project = project()
    provider = unique_module("Override")
    put_documents(project, [query_document(provider)])

    patch(EngineApi, :call_fresh, %{mode: :override, incomplete?: false, items: []})

    assert {:override, [{%Candidate.Function{name: "coalesce", arity: 2}, []}], true, []} =
             complete(project, "My.Query.from(user in Account, where: coa|")
  end

  test "merges all providers selected by the final scope" do
    project = project()
    first = unique_module("First")
    second = unique_module("Second")
    hover_provider = unique_module("Hover")
    test_pid = self()

    document =
      first
      |> query_document()
      |> put_in(
        [:scopes, :expressions, :data],
        expert: %{
          facets: %{
            completion: [
              {first, :complete, 1},
              {second, :complete, 1}
            ],
            hover: [{hover_provider, :provide, 1}]
          }
        }
      )

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn
      ^project, ^first, :complete, [_request], 10_000 ->
        [
          %{label: "first", kind: :field},
          %{label: "shared", kind: :field}
        ]

      ^project, ^second, :complete, [_request], 10_000 ->
        %{
          mode: :override,
          incomplete?: false,
          items: [
            %{label: "shared", kind: :field},
            %{label: "second", kind: :field}
          ]
        }

      ^project, ^hover_provider, :provide, [_request], 10_000 ->
        send(test_pid, :called_hover_provider)
        [%{label: "hover", kind: :text}]
    end)

    assert {:override,
            [
              {%Candidate.Generic{label: "first"}, []},
              {%Candidate.Generic{label: "shared"}, []},
              {%Candidate.Generic{label: "second"}, []}
            ], true, []} = complete(project, "My.Query.from(user in Account, where: value|")

    refute_receive :called_hover_provider
  end

  test "contains provider failures and validates at most 500 candidates" do
    project = project()
    provider = unique_module("Failure")
    put_documents(project, [query_document(provider)])

    patch(EngineApi, :call_fresh, fn _project, _module, _function, _args, _timeout ->
      raise "provider failed"
    end)

    assert :ignore = complete(project, "My.Query.from(user in Account, where: user.na|")

    candidates =
      Enum.map(0..500, fn index ->
        %{label: "item-#{index}", kind: :value}
      end)

    patch(EngineApi, :call_fresh, candidates)

    assert {:augment, result, true, []} =
             complete(project, "My.Query.from(user in Account, where: user.na|")

    assert length(result) == 500
    assert {%Candidate.Generic{label: "item-0"}, []} = hd(result)
    assert {%Candidate.Generic{label: "item-499"}, []} = List.last(result)

    patch(EngineApi, :call_fresh, [%{label: :invalid, kind: :field}])
    assert :ignore = complete(project, "My.Query.from(user in Account, where: user.na|")
  end

  defp complete(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Completion.complete(env)
  end

  defp put_documents(project, documents) do
    entries = semantic_entries(documents)

    patch(Store, :prefix, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints)}
    end)
  end

  defp query(entries, subject, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    Enum.filter(entries, fn entry ->
      String.starts_with?(entry.subject, subject) and
        constraint?(entry.type, type) and constraint?(entry.subtype, subtype)
    end)
  end

  defp constraint?(_value, :_), do: true
  defp constraint?(value, value), do: true
  defp constraint?(_value, _constraint), do: false

  defp semantic_entries(documents) do
    documents
    |> decode()
    |> Enum.with_index()
    |> Enum.map(fn {document, index} ->
      Entry.integration("/metadata.ex", "semantic", :dsl, "Metadata/#{index}", document)
    end)
  end

  defp decode(documents) do
    Decoder.decode(
      elixir_semantic_metadata: Enum.map(documents, &{:elixir_semantic_metadata_v1, &1})
    )
  end

  defp query_document(provider) do
    %{
      contexts: [
        %{
          mfa: {My.Query, :from, 2},
          argument: 1,
          scope: :query_options
        }
      ],
      scopes: %{
        query_options: %{
          entries: [
            %{
              kind: :keyword,
              name: :where,
              value_scope: :expressions
            }
          ]
        },
        expressions: %{
          entries: [
            %{
              kind: :function,
              mfa: {My.Query.API, :coalesce, 2},
              doc: "Returns the first non-null value."
            }
          ],
          data: [
            expert: %{
              facets: %{completion: [{provider, :complete, 1}]}
            }
          ]
        }
      }
    }
  end

  test "combines hover provider results before the entry documentation" do
    project = project()
    first = unique_module("HoverFirst")
    second = unique_module("HoverSecond")
    test_pid = self()

    document =
      first
      |> query_document()
      |> put_in(
        [:scopes, :expressions, :data],
        expert: %{facets: %{hover: [{first, :hover, 1}, {second, :hover, 1}]}}
      )

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn
      ^project, ^first, :hover, [request], 10_000 ->
        send(test_pid, {:hover_request, request})
        "First hover"

      ^project, ^second, :hover, [_request], 10_000 ->
        nil
    end)

    source = "My.Query.from(user in Account, where: coal|esce(user.name, 0))"

    assert [{"First hover", range}, {"Returns the first non-null value.", range}] =
             hover(project, source)

    assert_receive {:hover_request,
                    %{
                      name: "coalesce",
                      range: %{start: %{line: 1, character: 39}, end: %{line: 1, character: 47}},
                      semantic: %{scope: :expressions}
                    }}
  end

  test "returns signature help from every provider selected by the final scope" do
    project = project()
    first = unique_module("SignatureFirst")
    second = unique_module("SignatureSecond")
    test_pid = self()

    document =
      first
      |> query_document()
      |> put_in(
        [:scopes, :expressions, :data],
        expert: %{
          facets: %{signature_help: [{first, :signatures, 1}, {second, :signatures, 1}]}
        }
      )

    put_documents(project, [document])

    patch(EngineApi, :call_fresh, fn
      ^project, ^first, :signatures, [request], 10_000 ->
        send(test_pid, {:signature_request, request})

        [
          %{label: "coalesce(value, fallback)", parameters: ["value", "fallback"], doc: "Docs"},
          %{label: 1}
        ]

      ^project, ^second, :signatures, [_request], 10_000 ->
        [%{label: "nullif(left, right)", parameters: ["left", "right"]}]
    end)

    source = "My.Query.from(user in Account, where: coalesce(|"

    assert %{
             active_argument: 1,
             signatures: [
               %{
                 label: "coalesce(value, fallback)",
                 parameters: ["value", "fallback"],
                 doc: "Docs"
               },
               %{label: "nullif(left, right)", parameters: ["left", "right"], doc: nil}
             ]
           } = signature_help(project, source)

    assert_receive {:signature_request, %{active_argument: 1, semantic: %{scope: :expressions}}}
  end

  defp provider_data(provider) do
    %{facets: %{completion: [{provider, :complete, 1}]}}
  end

  defp hover(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Hover.hover(env)
  end

  defp signature_help(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    SignatureHelp.signature_help(env)
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
