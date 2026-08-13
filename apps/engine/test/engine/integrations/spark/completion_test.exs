defmodule Engine.Integrations.Spark.CompletionTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    entries = spark_entries()

    patch(Engine.ManagerApi, :search_store_exact, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints, :exact)}
    end)

    patch(Engine.ManagerApi, :search_store_prefix, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints, :prefix)}
    end)

    patch(Engine.ManagerApi, :search_store_all, fn _project, _constraints ->
      flunk("Spark completion must not read the full index")
    end)

    {:ok, project: project}
  end

  test "completes indexed use options and values", %{project: project} do
    assert {:override, [%Candidate.Snippet{label: "otp_app", snippet: "otp_app: :$0"}], []} =
             complete(project, "use Ash.Resource, otp_|")

    assert {:override, [%Candidate.Snippet{label: "enabled?", snippet: "enabled?: true"}], []} =
             complete(project, "use Ash.Resource, ena|")

    assert {:override, [%Candidate.Snippet{label: "true", snippet: "true"}], []} =
             complete(project, "use Ash.Resource, enabled?: t|")
  end

  test "completes sections, entities, patches, and documentation", %{project: project} do
    assert {:augment, [%Candidate.Snippet{label: "actions", documentation: "Actions"}], []} =
             complete(project, resource("act|"))

    assert {:augment,
            [%Candidate.Snippet{label: "read", documentation: "A read action", snippet: snippet}],
            []} = complete(project, resource("actions do\n  rea|\nend"))

    assert snippet =~ "read ${1:name}"

    assert {:override, [%Candidate.Snippet{label: "description"}], []} =
             complete(project, resource("actions do\n  read :all do\n    desc|\n  end\nend"))

    assert {:augment, candidates, []} =
             complete(project, resource("actions do\n  cre|\nend", ", extensions: [My.Patch]"))

    assert Enum.any?(candidates, &match?(%Candidate.Snippet{label: "create"}, &1))
  end

  test "resolves the DSL alias at the use position", %{project: project} do
    assert {:augment, [%Candidate.Snippet{label: "actions"}], []} =
             complete(
               project,
               """
               defmodule My.Resource do
                 alias Ash.Resource, as: ResourceDsl
                 use ResourceDsl
                 alias Other.Resource, as: ResourceDsl

                 act|
               end
               """
             )
  end

  test "replaces default single-kind extensions when configured", %{project: project} do
    assert {:augment, [%Candidate.Snippet{label: "default_section"}], []} =
             complete(project, resource("def|"))

    assert {:augment, [%Candidate.Snippet{label: "custom_section"}], []} =
             complete(project, resource("cus|", ", data_layer: My.CustomDataLayer"))
  end

  test "completes constrained modules, builtins, and functions", %{project: project} do
    assert {:override, [%Candidate.Module{full_name: "App.MyChange"}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, change: App|\nend")
             )

    assert {:override,
            [
              %Candidate.Function{
                name: "set_attribute",
                arity: 2,
                argument_names: ["arg1", "arg2"]
              }
            ], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, smart_change: set|\nend")
             )

    assert {:override, [%Candidate.Macro{name: "matches", argument_names: ["arg1"]}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, smart_change: mat|\nend")
             )

    assert {:override, [%Candidate.Function{name: "delegated", argument_names: ["arg1"]}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, smart_change: del|\nend")
             )

    assert {:override, [%Candidate.Module{full_name: "App.TypedChange"}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, typed_change: App|\nend")
             )

    assert {:override, [%Candidate.Snippet{label: "callback", snippet: snippet}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, call|\nend")
             )

    assert snippet =~ "fn ${1:arg1}, ${2:arg2} ->"
  end

  test "completes constraints for the selected Spark type", %{project: project} do
    assert {:override, [%Candidate.Snippet{label: "max_length"}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :foo, :string, constraints: [max|\nend")
             )

    assert {:override, [%Candidate.Snippet{label: "max"}], []} =
             complete(
               project,
               resource(
                 "attributes do\n  attribute :foo, :string, constraints: [range: [max|\nend"
               )
             )

    assert {:override, [%Candidate.Snippet{label: "max_length"}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :foo, My.CustomType, constraints: [max|\nend")
             )
  end

  test "completes indexed function options", %{project: project} do
    assert {:override, [%Candidate.Snippet{label: "upsert?", snippet: "upsert?: true"}], []} =
             complete(project, "Ash.create(changeset, :up|)")

    assert {:override, [%Candidate.Snippet{label: "upsert?", snippet: "upsert?: true"}], []} =
             complete(project, "changeset |> Ash.create(:up|)")
  end

  test "wraps strict list candidates only when outside a list", %{project: project} do
    assert {:override, [{%Candidate.Snippet{label: ":read"}, []}], true, []} =
             complete_raw(project, resource("actions do\n  configure modes: [:r|]\nend"))

    assert {:override, [{%Candidate.Snippet{label: ":read"}, [:wrap_list]}], true, []} =
             complete_raw(project, resource("actions do\n  configure modes: :r|\nend"))

    assert {:override, [{%Candidate.Snippet{label: ":read"}, []}], true, []} =
             complete_raw(project, resource("actions do\n  configure flexible: :r|\nend"))
  end

  test "augments unions containing an open type", %{project: project} do
    assert {:augment, [%Candidate.Module{full_name: "App.MyChange"}], []} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, mixed: App|\nend")
             )

    assert {:augment, [%Candidate.Module{full_name: "App.MyChange"}], [:wrap_list]} =
             complete(
               project,
               resource("attributes do\n  attribute :name, :string, mixed_list: App|\nend")
             )
  end

  test "ignores comments, strings, unrelated uses, and ordinary code", %{project: project} do
    assert :ignore = complete(project, resource(~S["rea|"]))
    assert :ignore = complete(project, "use Other.Library, opt|")
    assert :ignore = complete(project, resource("def ordinary do\n  Enum.ma|\nend"))
  end

  defp complete(project, source) do
    case complete_raw(project, source) do
      {mode, candidates, true, transforms} ->
        {mode, Enum.map(candidates, &elem(&1, 0)), transforms}

      :ignore ->
        :ignore
    end
  end

  defp complete_raw(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Engine.contextual_completion(env)
  end

  defp query(entries, subject, constraints, match_type) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    Enum.filter(entries, fn entry ->
      matches?(entry.subject, subject, match_type) and constraint?(entry.type, type) and
        constraint?(entry.subtype, subtype)
    end)
  end

  defp matches?(subject, query, :exact), do: subject == query
  defp matches?(subject, query, :prefix), do: String.starts_with?(subject, query)
  defp constraint?(_value, :_), do: true
  defp constraint?(value, value), do: true
  defp constraint?(_value, _constraint), do: false

  defp resource(body, use_options \\ "") do
    """
    defmodule My.Resource do
      use Ash.Resource#{use_options}

      #{body}
    end
    """
  end

  defp spark_entries do
    path = "/spark.ex"

    [
      Entry.integration(path, "spark", :dsl, Ash.Resource, %{
        default_extensions: ["Elixir.Ash.Resource.Extension", "Elixir.My.DefaultDataLayer"],
        default_extension_kinds: %{"data_layer" => ["Elixir.My.DefaultDataLayer"]},
        extension_kinds: ["extensions", "data_layer"],
        single_extension_kinds: ["data_layer"],
        options: [option("otp_app", :atom), option("enabled?", :boolean, "", false)]
      }),
      Entry.integration(path, "spark", :extension, Ash.Resource.Extension, %{
        added_extensions: ["Elixir.My.AttributeExtension"],
        patches: [],
        sections: [
          section("actions", [
            entity(
              "read",
              [%{name: "name", optional?: false}],
              [option("name", :atom), option("description", :string)],
              "A read action"
            ),
            entity("configure", [], [
              list_option("modes", :list),
              list_option("flexible", :wrap_list)
            ])
          ])
        ]
      }),
      Entry.integration(path, "spark", :extension, My.AttributeExtension, %{
        added_extensions: [],
        patches: [],
        sections: [
          section("attributes", [
            entity(
              "attribute",
              [%{name: "name", optional?: false}, %{name: "type", optional?: false}],
              [
                option("name", :atom),
                option("type", %{
                  kind: :spark_type,
                  behaviour: "Elixir.Ash.Type",
                  aliases: %{"string" => "Elixir.Ash.Type.String"}
                }),
                option("constraints", :keyword_list),
                option("change", behaviour_type()),
                option("smart_change", spark_behaviour_type()),
                option("typed_change", %{kind: :spark, type: "Elixir.My.Type"}),
                option("callback", %{kind: :function, arity: 2}),
                option("mixed", %{kind: :or, types: [%{kind: :atom}, behaviour_type()]}),
                option("mixed_list", %{
                  kind: :list,
                  item: %{kind: :or, types: [%{kind: :atom}, behaviour_type()]}
                })
              ]
            )
          ])
        ]
      }),
      Entry.integration(path, "spark", :extension, My.Patch, %{
        added_extensions: [],
        sections: [],
        patches: [%{section_path: ["actions"], entity: entity("create", [], [])}]
      }),
      extension(path, My.DefaultDataLayer, [section("default_section")]),
      extension(path, My.CustomDataLayer, [section("custom_section")]),
      relation(path, :behaviour, "Elixir.My.Change", "Elixir.App.MyChange"),
      relation(path, :behaviour, "Elixir.My.Change", "Elixir.App.SkippedChange", true),
      relation(path, :behaviour, "Elixir.Ash.Type", "Elixir.Ash.Type.String", false, %{
        constraints: [
          option("max_length", :non_neg_integer),
          option("range", %{
            kind: :keyword_list,
            options: [option("max", :non_neg_integer)]
          })
        ]
      }),
      relation(path, :behaviour, "Elixir.Ash.Type", "Elixir.My.CustomType", false, %{
        constraints: [option("max_length", :non_neg_integer)]
      }),
      relation(path, :type, "Elixir.My.Type", "Elixir.App.TypedChange"),
      Entry.integration(path, "spark", :function, "Ash.create/2/1", [
        option("upsert?", :boolean, "", false)
      ]),
      indexed_callable("My.Builtins.set_attribute/2", {:function, :public}),
      indexed_callable("My.Builtins.matches/1", {:macro, :public}),
      indexed_callable("My.Builtins.delegated/1", {:function, :delegate})
    ]
  end

  defp relation(path, kind, target, module, skip? \\ false, metadata \\ %{}) do
    entry =
      Entry.integration(
        path,
        "spark",
        kind,
        module,
        Map.merge(metadata, %{module: module, skip?: skip?})
      )

    %Entry{entry | subject: Entry.integration_subject("spark", kind, "#{target}/#{module}")}
  end

  defp indexed_callable(subject, type) do
    %Entry{
      id: System.unique_integer([:positive]),
      path: "/builtins.ex",
      subject: subject,
      subtype: :definition,
      type: type
    }
  end

  defp extension(path, module, sections) do
    Entry.integration(path, "spark", :extension, module, %{
      added_extensions: [],
      patches: [],
      sections: sections
    })
  end

  defp section(name, entities \\ []) do
    %{
      name: name,
      documentation: String.capitalize(name),
      snippet: nil,
      top_level?: false,
      options: [],
      sections: [],
      entities: entities
    }
  end

  defp entity(name, arguments, options, documentation \\ "") do
    %{
      name: name,
      documentation: documentation,
      snippet: nil,
      arguments: arguments,
      options: options,
      entities: []
    }
  end

  defp option(name, type, documentation \\ "", default \\ nil) do
    %{
      name: name,
      documentation: documentation,
      snippet: nil,
      default: default,
      type: if(is_map(type), do: type, else: %{kind: type})
    }
  end

  defp list_option(name, kind) do
    option(name, %{
      kind: kind,
      item: %{
        kind: :choices,
        values: [
          %{label: ":read", insert_text: ":read"},
          %{label: ":write", insert_text: ":write"}
        ]
      }
    })
  end

  defp behaviour_type, do: %{kind: :behaviour, behaviour: "Elixir.My.Change"}

  defp spark_behaviour_type do
    %{
      kind: :spark_behaviour,
      behaviour: "Elixir.My.Change",
      builtins: "My.Builtins"
    }
  end
end
