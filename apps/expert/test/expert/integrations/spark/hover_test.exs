defmodule Expert.Integrations.Spark.HoverTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.Integrations
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    entries = spark_entries()

    patch(Store, :exact, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints, :exact)}
    end)

    patch(Store, :prefix, fn ^project, subject, constraints ->
      {:ok, query(entries, subject, constraints, :prefix)}
    end)

    {:ok, project: project}
  end

  test "returns Spark documentation from runtime metadata", %{project: project} do
    for {source, expected} <- [
          {"use Ash.Resource, otp_|app: :my_app", "OTP application"},
          {resource("act|ions do\nend"), "Actions"},
          {resource("actions do\n  re|ad :all\nend"), "A read action"},
          {resource("actions do\n  tra|ce? true\nend"), "Trace actions"},
          {resource("actions do\n  read :all do\n    desc|ription \"All\"\n  end\nend"),
           "Description"},
          {resource("actions do\n  cre|ate :new\nend", ", extensions: [My.Patch]"),
           "A create action"},
          {resource(
             "attributes do\n  attribute :name, :string, constraints: [max_|length: 10]\nend"
           ), "Maximum length"},
          {resource(
             "attributes do\n  attribute :name, :string, constraints: [range: [ma|x: 10]]\nend"
           ), "Maximum value"},
          {"Ash.create(record, ups|ert?: true)", "Upsert"}
        ] do
      assert [{^expected, range}] = hover(project, source)
      assert range.start.line == range.end.line
      assert range.start.character < range.end.character
    end
  end

  test "ignores ordinary calls inside a Spark module", %{project: project} do
    assert [] = hover(project, resource("def ordinary, do: lo|cal_call()"))
  end

  test "does not use documentation from an unrelated nested option", %{project: project} do
    assert [] =
             hover(
               project,
               resource("attributes do\n  attribute :name, :string, constraints: [ma|x: 10]\nend")
             )
  end

  defp hover(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    Integrations.hover(env)
  end

  defp query(entries, subject, constraints, match_type) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    Enum.filter(entries, fn entry ->
      matches?(entry.subject, subject, match_type) and
        constraint?(entry.type, type) and constraint?(entry.subtype, subtype)
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
        default_extensions: ["Elixir.Ash.Resource.Extension"],
        default_extension_kinds: %{},
        extension_kinds: ["extensions"],
        single_extension_kinds: [],
        options: [option("otp_app")]
      }),
      Entry.integration(path, "spark", :extension, Ash.Resource.Extension, %{
        added_extensions: ["Elixir.My.AttributeExtension"],
        patches: [],
        sections: [
          section(
            "actions",
            [
              entity("read", [option("description")])
            ],
            [option("trace?")]
          )
        ]
      }),
      Entry.integration(path, "spark", :extension, My.AttributeExtension, %{
        added_extensions: [],
        patches: [],
        sections: [
          section("attributes", [
            %{
              entity("attribute", [
                %{
                  option("type")
                  | type: %{
                      kind: :spark_type,
                      behaviour: "Elixir.Ash.Type",
                      aliases: %{"string" => "Elixir.Ash.Type.String"}
                    }
                }
              ])
              | arguments: [
                  %{name: "name", optional?: false},
                  %{name: "type", optional?: false}
                ]
            }
          ])
        ]
      }),
      Entry.integration(path, "spark", :extension, My.Patch, %{
        added_extensions: [],
        sections: [],
        patches: [
          %{section_path: ["actions"], entity: entity("create", [])}
        ]
      }),
      relation(path, "Elixir.Ash.Type", "Elixir.Ash.Type.String", %{
        constraints: [
          option("max_length"),
          %{
            option("range")
            | type: %{
                kind: :keyword_list,
                options: [option("max")]
              }
          }
        ]
      }),
      Entry.integration(path, "spark", :function, "Ash.create/2/1", [
        option("upsert?")
      ])
    ]
  end

  defp relation(path, target, module, metadata) do
    entry =
      Entry.integration(
        path,
        "spark",
        :behaviour,
        module,
        Map.merge(metadata, %{module: module, skip?: false})
      )

    %Entry{
      entry
      | subject: Entry.integration_subject("spark", :behaviour, "#{target}/#{module}")
    }
  end

  defp section(name, entities, options \\ []) do
    %{
      name: name,
      documentation: documentation(name),
      snippet: nil,
      top_level?: false,
      options: options,
      sections: [],
      entities: entities
    }
  end

  defp entity(name, options) do
    %{
      name: name,
      documentation: documentation(name),
      snippet: nil,
      arguments: [],
      options: options,
      entities: []
    }
  end

  defp option(name) do
    %{
      name: name,
      documentation: documentation(name),
      snippet: nil,
      default: nil,
      type: %{kind: :atom}
    }
  end

  defp documentation("otp_app"), do: "OTP application"
  defp documentation("actions"), do: "Actions"
  defp documentation("read"), do: "A read action"
  defp documentation("trace?"), do: "Trace actions"
  defp documentation("description"), do: "Description"
  defp documentation("create"), do: "A create action"
  defp documentation("max_length"), do: "Maximum length"
  defp documentation("max"), do: "Maximum value"
  defp documentation("upsert?"), do: "Upsert"
  defp documentation(_name), do: ""
end
