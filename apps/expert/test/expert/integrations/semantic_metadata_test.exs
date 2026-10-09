defmodule Expert.Integrations.SemanticMetadataTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  @tag :tmp_dir
  test "reads v1 documents from BEAM attributes without loading the producer", %{tmp_dir: tmp_dir} do
    module = unique_module("Beam")
    document = base_document()
    attribute = inspect({:elixir_semantic_metadata_v1, document}, limit: :infinity)

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
          accumulate: true,
          persist: true
        )

        @elixir_semantic_metadata #{attribute}
      end
      """)

    :code.purge(module)
    :code.delete(module)
    refute :code.is_loaded(module)

    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    assert [
             %{
               kind: :dsl,
               contexts: [_context],
               scopes: %{root: %{entries: [_entry], data: []}}
             }
           ] =
             Decoder.decode(attributes)

    entries =
      Integrations.index_beam(
        project(),
        binary,
        %{module: module, attributes: attributes},
        Path.join(tmp_dir, "metadata.ex")
      )

    assert [%Entry{subtype: :integration, metadata: %{payload: %{kind: :dsl}}}] = entries
    refute :code.is_loaded(module)
  end

  test "validates each document atomically" do
    valid = base_document()
    missing_scope = put_in(valid, [:contexts, Access.at(0), :scope], :missing)

    duplicate_context =
      Map.update!(valid, :contexts, fn [context] -> [context, context] end)

    executable =
      put_in(valid, [:scopes, :root, :entries], [
        %{kind: :literal, value: fn -> :unsafe end}
      ])

    unsafe_data = put_in(valid, [:scopes, :root, :data], other: fn -> :unsafe end)

    attributes = [
      elixir_semantic_metadata: [
        {:elixir_semantic_metadata_v1, missing_scope},
        {:elixir_semantic_metadata_v1, valid},
        {:elixir_semantic_metadata_v1, duplicate_context},
        {:elixir_semantic_metadata_v1, executable},
        {:elixir_semantic_metadata_v1, unsafe_data}
      ]
    ]

    assert [%{kind: :dsl}] = Decoder.decode(attributes)
  end

  test "uses a generic candidate for an unknown entry kind" do
    document =
      put_in(base_document(), [:scopes, :root, :entries], [
        %{kind: :future_kind, mfa: {My.DSL, :value, 0}}
      ])

    project = project_with_documents([document])

    assert {:augment, [{%Candidate.Generic{label: "value/0", kind: :future_kind}, []}], true, []} =
             complete(project, "My.DSL.configure do\n  val|\nend")
  end

  test "does not impose a collection or term depth limit on the flat graph" do
    entries =
      for index <- 1..1_100 do
        %{kind: :literal, value: index}
      end

    document = put_in(base_document(), [:scopes, :root, :entries], entries)

    assert [%{scopes: %{root: %{entries: decoded}}}] = decode([document])
    assert length(decoded) == 1_100
  end

  test "completes Ecto-style expressions in a keyword value" do
    document = %{
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
            },
            %{
              kind: :keyword,
              name: :select,
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
          ]
        }
      }
    }

    project = project_with_documents([document])

    source = """
    defmodule QueryExample do
      import My.Query

      from user in User, where: coal|
    end
    """

    assert {:augment,
            [
              {%Candidate.Function{
                 name: "coalesce",
                 arity: 2,
                 argument_names: ["arg1", "arg2"],
                 summary: "Returns the first non-null value."
               }, []}
            ], true, []} = complete(project, source)

    assert [{"Returns the first non-null value.", _range}] =
             hover(project, String.replace(source, "coal|", "coal|esce"))
  end

  test "selects the scope for a nested call" do
    document = %{
      contexts: [
        %{
          mfa: {My.DSL, :configure, 1},
          block: :do,
          scope: :root
        },
        %{
          mfa: {My.DSL, :section, 1},
          block: :do,
          scope: :section
        },
        %{
          mfa: {My.DSL, :isolated, 1},
          block: :do,
          scope: :isolated
        }
      ],
      scopes: %{
        root: %{
          entries: [
            %{kind: :function, mfa: {My.DSL, :section, 1}},
            %{kind: :function, mfa: {My.DSL, :isolated, 1}},
            %{kind: :function, mfa: {My.DSL, :root_value, 0}}
          ]
        },
        section: %{
          entries: [%{kind: :function, mfa: {My.DSL, :section_value, 0}}]
        },
        isolated: %{
          entries: [%{kind: :function, mfa: {My.DSL, :isolated_value, 0}}]
        }
      }
    }

    project = project_with_documents([document])

    assert labels(complete(project, nested_source("section", "|"))) == ["section_value/0"]

    assert labels(complete(project, nested_source("isolated", "|"))) == ["isolated_value/0"]
  end

  test "selects a separate scope for every block" do
    contexts =
      for key <- [:do, :else, :after, :rescue, :catch] do
        %{
          mfa: {My.DSL, :configure, 1},
          block: key,
          scope: key
        }
      end

    scopes =
      Map.new([:do, :else, :after, :rescue, :catch], fn key ->
        {key,
         %{
           entries: [
             %{kind: :function, mfa: {My.DSL, String.to_atom("#{key}_value"), 0}}
           ]
         }}
      end)

    project = project_with_documents([%{contexts: contexts, scopes: scopes}])

    for key <- [:do, :else, :after, :rescue, :catch] do
      source = """
      My.DSL.configure do
        #{if key == :do, do: "|", else: ":ok"}
      else
        #{if key == :else, do: "|", else: ":ok"}
      rescue
        #{if key == :rescue, do: "|", else: ":ok"}
      catch
        #{if key == :catch, do: "|", else: ":ok"}
      after
        #{if key == :after, do: "|", else: ":ok"}
      end
      """

      assert labels(complete(project, source)) == ["#{key}_value/0"]
    end
  end

  test "follows static value edges and recursive scopes" do
    document = %{
      contexts: [
        %{
          mfa: {My.DSL, :configure, 1},
          argument: 0,
          scope: :options
        }
      ],
      scopes: %{
        options: %{
          entries: [
            %{
              kind: :keyword,
              name: :options,
              value_scope: :options
            },
            %{
              kind: :keyword,
              name: :mode,
              value_scope: :modes
            }
          ]
        },
        modes: %{
          entries: [
            %{kind: :literal, value: :open},
            %{kind: :literal, value: :closed}
          ]
        }
      }
    }

    project = project_with_documents([document])

    assert labels(complete(project, "My.DSL.configure(mode: :op|)")) == [":open"]

    assert labels(complete(project, "My.DSL.configure(options: [options: [mode: :cl|]])")) ==
             [":closed"]
  end

  @tag :tmp_dir
  test "reads EEP-48 documentation pointers without loading the target module", %{
    tmp_dir: tmp_dir
  } do
    module = unique_module("Documented")
    source_path = Path.join(tmp_dir, "documented.ex")
    beam_path = Path.join(tmp_dir, Atom.to_string(module) <> ".beam")
    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    File.write!(source_path, """
    defmodule #{inspect(module)} do
      @doc "Pointer documentation."
      def value, do: :ok
    end
    """)

    assert {:ok, [^module], %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir,
               return_diagnostics: true
             )

    :code.purge(module)
    :code.delete(module)
    refute :code.is_loaded(module)

    document = %{
      contexts: [
        %{
          mfa: {My.DSL, :configure, 1},
          block: :do,
          scope: :root
        }
      ],
      scopes: %{
        root: %{
          entries: [
            %{
              kind: :function,
              mfa: {module, :value, 0},
              doc: {module, :function, :value, 0}
            }
          ]
        }
      }
    }

    project = project_with_documents([document])
    patch(ModuleRegistry, :beam_path, fn ^project, ^module -> beam_path end)

    assert {:augment, [{%Candidate.Function{summary: "Pointer documentation."}, []}], true, []} =
             complete(project, "My.DSL.configure do\n  val|\nend")

    assert [{"Pointer documentation.", _range}] =
             hover(project, "My.DSL.configure do\n  val|ue\nend")

    refute :code.is_loaded(module)
  end

  defp complete(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Integrations.complete(env)
  end

  defp hover(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Integrations.hover(env)
  end

  defp labels({:augment, candidates, true, []}) do
    candidates
    |> Enum.map(fn
      {%{name: name, arity: arity}, []} -> "#{name}/#{arity}"
      {candidate, []} -> candidate.label
    end)
    |> Enum.sort()
  end

  defp project_with_documents(documents) do
    entries = beam_entries(documents)
    project = project()

    patch(Store, :prefix, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints)}
    end)

    project
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

  defp beam_entries(documents) do
    module = unique_module("Metadata")

    attributes =
      Enum.map_join(documents, "\n", fn document ->
        value = inspect({:elixir_semantic_metadata_v1, document}, limit: :infinity)
        "@elixir_semantic_metadata #{value}"
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

    :code.purge(module)
    :code.delete(module)
    {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    Integrations.index_beam(
      project(),
      binary,
      %{module: module, attributes: attributes},
      "/metadata.ex"
    )
  end

  defp decode(documents) do
    Decoder.decode(
      elixir_semantic_metadata: Enum.map(documents, &{:elixir_semantic_metadata_v1, &1})
    )
  end

  defp base_document do
    %{
      contexts: [
        %{
          mfa: {My.DSL, :configure, 1},
          block: :do,
          scope: :root
        }
      ],
      scopes: %{
        root: %{entries: [%{kind: :function, mfa: {My.DSL, :value, 0}}]}
      }
    }
  end

  defp nested_source(call, body) do
    """
    My.DSL.configure do
      #{call} do
        #{body}
      end
    end
    """
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
