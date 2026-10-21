defmodule ExpertEctoTest do
  use ExUnit.Case, async: true

  alias ExpertEcto.Test.Post
  alias ExpertExtensions.Test.Request

  @calls %{
    from: Ecto.Query,
    field: Ecto.Schema,
    belongs_to: Ecto.Schema,
    embeds_one: Ecto.Schema
  }

  describe "metadata" do
    test "registers the completion handler on the scopes that depend on the project" do
      assert [{:elixir_semantic_metadata_v1, %{scopes: scopes}}] =
               ExpertEcto.module_info(:attributes)
               |> Keyword.get_values(:elixir_semantic_metadata)
               |> List.flatten()

      handler = [expert: %{facets: %{completion: [{ExpertEcto, :complete, 1}]}}]

      for scope <- [:expressions, :query_sources, :field_types] do
        assert scopes[scope].data == handler
      end

      assert scopes.schemas.data == [
               expert: %{
                 facets: %{
                   completion: [{ExpertEcto, :complete, 1}],
                   resolve: [{ExpertEcto, :resolve, 1}]
                 }
               }
             ]
    end

    test "describes the options of from/2 and their value scopes" do
      options = document().scopes.query_options.entries

      assert %{value_scope: :expressions, doc: {Ecto.Query, :macro, :where, 3}} =
               Enum.find(options, &(&1.name == :where))

      assert %{value_scope: :query_sources} = Enum.find(options, &(&1.name == :left_join))
      assert %{value_scope: :update_operations} = Enum.find(options, &(&1.name == :update))
      assert %{value_scope: :empty} = Enum.find(options, &(&1.name == :preload))
      assert %{value_scope: :booleans} = Enum.find(options, &(&1.name == :with_ties))
    end

    test "describes the query and window functions with the arity of their docs" do
      entries = document().scopes.expressions.entries

      assert %{doc: {Ecto.Query.API, :function, :json_extract_path, 2}} =
               Enum.find(entries, &(&1.mfa == {Ecto.Query.API, :json_extract_path, 2}))

      assert %{doc: {Ecto.Query.WindowAPI, :function, :lead, 3}} =
               Enum.find(entries, &(&1.mfa == {Ecto.Query.WindowAPI, :lead, 1}))
    end

    test "selects scopes in the arguments of query macros" do
      contexts = document().contexts

      assert %{scope: :query_sources} = context(contexts, {Ecto.Query, :from, 1}, 0)
      assert %{scope: :query_options} = context(contexts, {Ecto.Query, :from, 2}, 1)
      assert %{scope: :expressions} = context(contexts, {Ecto.Query, :where, 3}, 2)
      assert %{scope: :query_sources} = context(contexts, {Ecto.Query, :join, 3}, 2)
      assert %{scope: :query_sources} = context(contexts, {Ecto.Query, :join, 4}, 3)
      assert %{scope: :query_sources} = context(contexts, {Ecto.Query, :join, 5}, 3)
      assert %{scope: :join_options} = context(contexts, {Ecto.Query, :join, 5}, 4)
      assert %{scope: :update_operations} = context(contexts, {Ecto.Query, :update, 3}, 2)
    end

    test "describes the types and options of schema fields" do
      %{contexts: contexts, scopes: scopes} = document()

      assert %{scope: :field_types} = context(contexts, {Ecto.Schema, :field, 2}, 1)
      assert %{scope: :field_types} = context(contexts, {Ecto.Schema, :field, 3}, 1)
      assert %{scope: :field_options} = context(contexts, {Ecto.Schema, :field, 3}, 2)

      assert %{doc: "Loads as `String.t()`, UTF-8 encoded."} =
               Enum.find(scopes.field_types.entries, &(&1.value == :string))

      assert %{value_scope: :booleans, doc: {Ecto.Schema, :macro, :field, 3}} =
               Enum.find(scopes.field_options.entries, &(&1.name == :virtual))
    end

    test "describes the targets and options of associations and embeds" do
      %{contexts: contexts, scopes: scopes} = document()

      for macro <- [:belongs_to, :has_one, :has_many, :many_to_many, :embeds_one, :embeds_many] do
        assert %{scope: :schemas} = context(contexts, {Ecto.Schema, macro, 2}, 1)
        assert %{scope: :schemas} = context(contexts, {Ecto.Schema, macro, 3}, 1)
        options = :"#{macro}_options"
        assert %{scope: ^options} = context(contexts, {Ecto.Schema, macro, 3}, 2)
      end

      assert %{value_scope: :on_delete} =
               Enum.find(scopes.has_many_options.entries, &(&1.name == :on_delete))

      assert Enum.map(scopes.many_to_many_on_delete.entries, & &1.value) == [
               :nothing,
               :delete_all
             ]
    end

    test "describes the column types of migrations" do
      %{contexts: contexts, scopes: scopes} = document()

      assert %{scope: :column_types} = context(contexts, {Ecto.Migration, :add, 2}, 1)
      assert %{scope: :column_types} = context(contexts, {Ecto.Migration, :add, 3}, 1)
      assert Enum.any?(scopes.column_types.entries, &(&1.value == :utc_datetime))
    end
  end

  describe "query expressions" do
    test "complete the fields of the schema of the source binding" do
      assert [%{label: "name", insert_text: "name", kind: :field}] =
               complete("from post in Post, where: post.na|", :expressions)
    end

    test "expand an alias with a suffix in a remote from/2" do
      assert [%{label: "nickname"}] =
               complete("Ecto.Query.from(post in Models.Post, select: post.nick|", :expressions,
                 aliases: %{[:Models] => ExpertEcto.Test}
               )
    end

    test "complete the fields of a join binding and of an assoc/2 join" do
      assert [%{label: "body"}] =
               complete(
                 "from post in Post, left_join: comment in ExpertEcto.Test.Comment, where: comment.bo|",
                 :expressions
               )

      assert [%{label: "body"}] =
               complete(
                 "from post in Post, left_join: comment in assoc(post, :comments), where: comment.bo|",
                 :expressions
               )
    end

    test "complete the names of the bindings" do
      source = "from post in Post, left_join: comment in assoc(post, :comments), where: |"

      assert ["post", "comment"] = source |> complete(:expressions) |> Enum.map(& &1.label)

      assert [%{label: "comment", kind: :variable}] =
               complete(String.replace(source, "|", "co|"), :expressions)
    end

    test "return no fields for an unknown binding or a source that is not a schema" do
      assert [] = complete("from post in Post, where: author.na|", :expressions)
      assert [] = complete("from post in query, where: post.na|", :expressions)
    end
  end

  describe "query sources" do
    test "complete the schemas after `in`" do
      assert ["ExpertEcto.Test.Post"] =
               "from post in Po|"
               |> complete(:query_sources, module: "ExpertEcto.Test.Queries")
               |> Enum.map(& &1.label)
    end

    test "complete schemas by full name outside of the namespace of the module" do
      assert ["ExpertEcto.Test.Post"] =
               "from post in ExpertEcto.Test.Po|"
               |> complete(:query_sources, module: "Elsewhere")
               |> Enum.map(& &1.label)

      assert [] = "from post in Po|" |> complete(:query_sources, module: "Elsewhere")
    end

    test "complete the associations of a binding in assoc/2" do
      assert [%{label: ":comments", insert_text: ":comments"}] =
               complete(
                 "from post in Post, left_join: comment in assoc(post, :co|",
                 :query_sources
               )
    end
  end

  describe "field types" do
    test "complete composite types over the typed text" do
      assert [
               %{
                 label: "{:array, inner_type}",
                 snippet: "{:array, ${1:inner_type}}",
                 range: range
               }
             ] =
               complete("field :tags, :ar|", :field_types)

      assert range == %{start: %{line: 1, character: 14}, end: %{line: 1, character: 17}}
    end

    test "counts each codepoint as one column" do
      prefix = ~s(field :"é😀", :ar)
      cursor = String.length(prefix) + 1

      assert [%{range: range}] = complete(prefix <> "|", :field_types)

      assert range == %{
               start: %{line: 1, character: cursor - 3},
               end: %{line: 1, character: cursor}
             }
    end

    test "complete the custom types of the project" do
      assert ["ExpertEcto.Test.Money"] =
               "field :price, Mo|"
               |> complete(:field_types, module: "ExpertEcto.Test.Post")
               |> Enum.map(& &1.label)
    end
  end

  describe "association targets" do
    test "complete the schemas of the project" do
      assert ["ExpertEcto.Test.Comment"] =
               "belongs_to :reply, Com|"
               |> complete(:schemas, module: "ExpertEcto.Test.Comment")
               |> Enum.map(& &1.label)
    end
  end

  describe "resolve" do
    test "resolves the schema of an inline embed inside the module" do
      source = """
      schema "events" do
        embeds_one :metadata, Meta|data, primary_key: false do
          field :id, :string
        end
      end
      """

      assert %{entity: %{kind: :module, module: ExpertEcto.Test.Event.Metadata}} ==
               resolve(source, module: "ExpertEcto.Test.Event")
    end

    test "resolves the schema of an inline embed inside another inline embed" do
      source = """
      embedded_schema do
        embeds_one :metadata, Metadata do
          embeds_one :sink, Si|nk do
            field :id, :string
          end
        end
      end
      """

      assert %{entity: %{module: ExpertEcto.Test.Event.Metadata.Sink}} =
               resolve(source, module: "ExpertEcto.Test.Event")
    end

    test "returns nil for the schema of an association" do
      assert nil ==
               resolve("belongs_to :post, Po|st", module: "ExpertEcto.Test", aliases: %{})
    end

    test "returns nil for the schema of an embed without a block" do
      assert nil == resolve("embeds_one :metadata, Meta|data", module: "ExpertEcto.Test.Event")
    end

    test "does not create atoms for unknown modules" do
      suffix = System.unique_integer([:positive])
      parent = "Unknown#{suffix}"
      embedded = "Elixir.#{parent}.Metadata"
      source = "embeds_one :metadata, Meta|data do\nend"

      refute existing_atom?("Elixir." <> parent)
      refute existing_atom?(embedded)

      assert nil == resolve(source, module: parent)

      refute existing_atom?("Elixir." <> parent)
      refute existing_atom?(embedded)
    end
  end

  defp complete(source, scope, opts \\ []),
    do: source |> request(scope, opts) |> ExpertEcto.complete()

  defp resolve(source, opts), do: source |> request(:schemas, opts) |> ExpertEcto.resolve()

  defp request(source, scope, opts) do
    name =
      source
      |> Request.build()
      |> Map.fetch!(:ancestors)
      |> Enum.find_value(fn
        {{:., _, [_module, name]}, _meta, _arguments} when is_map_key(@calls, name) -> name
        {name, _meta, _arguments} when is_map_key(@calls, name) -> name
        _ancestor -> nil
      end)

    opts = Keyword.put_new(opts, :aliases, %{[:Post] => Post})
    Request.build(source, [call: {Map.fetch!(@calls, name), name}, scope: scope] ++ opts)
  end

  defp document, do: ExpertEcto.Metadata.document()

  defp context(contexts, mfa, argument),
    do: Enum.find(contexts, &(&1[:mfa] == mfa and &1[:argument] == argument))

  defp existing_atom?(name) do
    String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
