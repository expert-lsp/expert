defmodule Expert.Integrations.SemanticMetadata.CompletionTest do
  use Expert.Test.SemanticMetadataCase, async: false

  alias Expert.Integrations.SemanticMetadata.Completion.Result
  alias Expert.Test.EnumUse
  alias Forge.Completion.Candidate

  @blocks [:do, :else, :after, :rescue, :catch]

  test "completes an entry of an unknown kind as a generic item", %{project: project} do
    put_documents(project, [
      dsl_document(%{root: %{entries: [%{kind: :future_kind, mfa: {My.DSL, :value, 0}}]}})
    ])

    assert %Result{
             mode: :augment,
             candidates: [%Candidate.Generic{label: "value/0", kind: :future_kind}],
             incomplete?: true
           } =
             complete(project, "My.DSL.configure do\n  val|\nend")
  end

  test "completes and documents the functions in the value scope of a keyword", %{
    project: project
  } do
    put_documents(project, [query_document()])

    assert %Result{
             mode: :augment,
             candidates: [
               %Candidate.Function{
                 name: "coalesce",
                 arity: 2,
                 argument_names: ["arg1", "arg2"],
                 summary: "Returns the first non-null value."
               }
             ],
             incomplete?: true
           } = complete(project, "import My.Query\nfrom user in User, where: coal|")
  end

  test "has no scope in the value of a key without a value scope", %{project: project} do
    put_documents(project, [query_document()])

    assert %Result{mode: :ignore} =
             complete(project, "import My.Query\nfrom user in User, limit: |")
  end

  test "matches a call by its arity, counting the arguments after the cursor", %{
    project: project
  } do
    put_documents(project, [
      %{
        contexts: [
          %{mfa: {My.Repo, :insert, 2}, argument: 0, scope: :changesets},
          %{mfa: {My.DSL, :field, 3}, argument: 1, scope: :types}
        ],
        scopes: %{
          changesets: %{entries: [%{kind: :function, mfa: {My.Changesets, :changeset, 0}}]},
          types: %{entries: [%{kind: :literal, value: :string}]}
        }
      }
    ])

    assert labels(complete(project, "My.Repo.insert(chan|, returning: true)")) == ["changeset/0"]
    assert %Result{mode: :ignore} = complete(project, "My.Repo.insert(chan|)")

    assert labels(complete(project, "My.DSL.field :name, :st|, default: \"\"")) == [":string"]
  end

  test "selects the scope of the innermost call", %{project: project} do
    put_documents(project, [
      %{
        contexts: [
          %{mfa: {My.DSL, :configure, 1}, block: :do, scope: :root},
          %{mfa: {My.DSL, :section, 1}, block: :do, scope: :section}
        ],
        scopes: %{
          root: %{
            entries: [
              %{kind: :function, mfa: {My.DSL, :section, 1}},
              %{kind: :function, mfa: {My.DSL, :root_value, 0}}
            ]
          },
          section: %{entries: [%{kind: :function, mfa: {My.DSL, :section_value, 0}}]}
        }
      }
    ])

    source = """
    My.DSL.configure do
      section do
        |
      end
    end
    """

    assert labels(complete(project, source)) == ["section_value/0"]
  end

  test "selects the scope of each block", %{project: project} do
    put_documents(project, [
      %{
        contexts:
          for(block <- @blocks, do: %{mfa: {My.DSL, :configure, 1}, block: block, scope: block}),
        scopes:
          Map.new(@blocks, fn block ->
            {block, %{entries: [%{kind: :function, mfa: {My.DSL, :"#{block}_value", 0}}]}}
          end)
      }
    ])

    for block <- @blocks do
      slot = fn key -> if key == block, do: "|", else: ":ok" end

      source = """
      My.DSL.configure do
        #{slot.(:do)}
      else
        #{slot.(:else)}
      rescue
        #{slot.(:rescue)}
      catch
        #{slot.(:catch)}
      after
        #{slot.(:after)}
      end
      """

      assert labels(complete(project, source)) == ["#{block}_value/0"]
    end
  end

  test "completes the value scope of a key, including a scope that refers to itself", %{
    project: project
  } do
    put_documents(project, [
      %{
        contexts: [%{mfa: {My.DSL, :configure, 1}, argument: 0, scope: :options}],
        scopes: %{
          options: %{
            entries: [
              %{kind: :keyword, name: :options, value_scope: :options},
              %{kind: :keyword, name: :mode, value_scope: :modes}
            ]
          },
          modes: %{
            entries: [%{kind: :literal, value: :open}, %{kind: :literal, value: :closed}]
          }
        }
      }
    ])

    assert labels(complete(project, "My.DSL.configure(mode: :op|)")) == [":open"]

    assert labels(complete(project, "My.DSL.configure(options: [options: [mode: :cl|]])")) ==
             [":closed"]
  end

  @tag :tmp_dir
  test "documents an entry with the docs of the function its doc references", %{
    project: project,
    tmp_dir: tmp_dir
  } do
    module =
      register_beam!(project, tmp_dir, """
      defmodule #{inspect(unique_module("Documented"))} do
        @doc "Pointer documentation."
        def value, do: :ok
      end
      """)

    put_documents(project, [
      dsl_document(%{
        root: %{
          entries: [
            %{kind: :function, mfa: {module, :value, 0}, doc: {module, :function, :value, 0}}
          ]
        }
      })
    ])

    assert %Result{
             mode: :augment,
             candidates: [%Candidate.Function{summary: "Pointer documentation."}],
             incomplete?: true
           } =
             complete(project, "My.DSL.configure do\n  val|\nend")

    refute :code.is_loaded(module)
  end

  @tag :tmp_dir
  test "names the arguments of a function entry from its docs", %{
    project: project,
    tmp_dir: tmp_dir
  } do
    module =
      register_beam!(project, tmp_dir, """
      defmodule #{inspect(unique_module("Arguments"))} do
        @doc deprecated: "Use another function."
        def value(name, opts \\\\ []), do: {name, opts}
      end
      """)

    put_documents(project, [
      dsl_document(%{root: %{entries: [%{kind: :function, mfa: {module, :value, 2}}]}})
    ])

    assert %Result{mode: :augment, candidates: [%Candidate.Function{} = candidate]} =
             complete(project, "My.DSL.configure do\n  val|\nend")

    assert candidate.argument_names == ["name", "opts"]
    assert candidate.metadata.deprecated == "Use another function."
  end

  describe "a context of an imported function" do
    setup %{project: project} do
      put_documents(project, [
        %{
          contexts: [%{mfa: {Enum, :map, 2}, argument: 1, scope: :mapper}],
          scopes: %{
            mapper: %{entries: [%{kind: :function, mfa: {My.Mapper, :scope_value, 0}}]}
          }
        }
      ])
    end

    for {directive, declaration} <- [
          import: "import Enum, only: [map: 2]",
          use: "use #{inspect(EnumUse)}"
        ] do
      test "applies after #{directive} in the same function", %{project: project} do
        source = imported_source(unquote(declaration), inside: "map([], scope_val|)")

        assert labels(complete(project, source)) == ["scope_value/0"]
      end

      test "applies only after #{directive}", %{project: project} do
        source = imported_source(unquote(declaration), before: "map([], scope_val|)")

        assert %Result{mode: :ignore} = complete(project, source)
      end

      test "applies only in the function with #{directive}", %{project: project} do
        source = imported_source(unquote(declaration), sibling: "map([], scope_val|)")

        assert %Result{mode: :ignore} = complete(project, source)
      end
    end

    test "applies in an unclosed call after use", %{project: project} do
      source = """
      defmodule ScopeExample do
        use #{inspect(EnumUse)}
        map([], scope_val|
      end
      """

      assert labels(complete(project, source)) == ["scope_value/0"]
    end
  end

  defp imported_source(declaration, [{location, code}]) do
    slot = fn slot -> if slot == location, do: code, else: ":ok" end

    """
    defmodule ScopeExample do
      def foo do
        #{slot.(:before)}
        #{declaration}
        #{slot.(:inside)}
      end

      def bar do
        #{slot.(:sibling)}
      end
    end
    """
  end

  defp labels(%Result{mode: :augment, candidates: candidates, incomplete?: true}) do
    candidates
    |> Enum.map(fn
      %{name: name, arity: arity} -> "#{name}/#{arity}"
      candidate -> candidate.label
    end)
    |> Enum.sort()
  end

  defp dsl_document(scopes) do
    %{contexts: [%{mfa: {My.DSL, :configure, 1}, block: :do, scope: :root}], scopes: scopes}
  end

  defp query_document do
    %{
      contexts: [%{mfa: {My.Query, :from, 2}, argument: 1, scope: :query_options}],
      scopes: %{
        query_options: %{
          entries: [
            %{kind: :keyword, name: :where, value_scope: :expressions},
            %{kind: :keyword, name: :limit}
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
  end
end
