defmodule Expert.Search.Indexer.Extractors.EctoSchemaTest do
  use Expert.Test.ExtractorCase

  def index(source) do
    do_index(source, fn entry -> entry.type == :struct end)
  end

  describe "finds the structs defined by schema" do
    test "only finds if Ecto.Schema is used" do
      {:ok, results, _} =
        ~q[
         defmodule NotEcto do
           schema "not ecto" do
             field :ecto, :boolean, default: false
           end
         end
        ]
        |> index()

      assert results == []
    end

    test "if ecto.schema is aliased" do
      {:ok, [struct], _doc} =
        ~q[
         defmodule MySchema do
           alias Ecto.Schema , as: SCM
           use SCM
           schema "my_schema" do
             field :last_name, :string
           end
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :definition
    end

    test "consisting of a single field" do
      {:ok, [struct], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
           schema "my_schema" do
             field :last_name, :string
           end
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :definition

      expected =
        ~q[
        schema "my_schema" do
            field :last_name, :string
          end
        ]
        |> String.trim()

      assert decorate(doc, struct.range) =~ ~q[«schema "my_schema" do»]
      assert extract(doc, struct.block_range) =~ expected
    end

    test "consisting of multiple fields" do
      {:ok, [struct], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
           schema "my_schema" do
             field :first_name, :string
             field :last_name, :string
           end
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :definition

      expected =
        ~q[
        schema "my_schema" do
            field :first_name, :string
            field :last_name, :string
          end
        ]
        |> String.trim()

      assert decorate(doc, struct.range) =~ ~q[«schema "my_schema" do»]
      assert extract(doc, struct.block_range) =~ expected
    end
  end

  describe "finds the structs defined by embedded_schema" do
    test "only finds if Ecto.Schema is used" do
      {:ok, results, _doc} =
        ~q[
         defmodule NotEcto do
           schema "not ecto" do
             embedded_schema "also_not_ecto" do
               field :very_much_like_ecto, :string
             end
           end
         end
        ]
        |> index()

      assert [] == results
    end

    test "consisting of a single field" do
      {:ok, [struct], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
           embedded_schema do
             field :last_name, :string
           end
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :definition

      expected =
        ~q[
        embedded_schema do
            field :last_name, :string
          end
        ]
        |> String.trim()

      assert decorate(doc, struct.range) =~ ~q[«embedded_schema do»]
      assert extract(doc, struct.block_range) =~ expected
    end

    test "consisting of multiple fields" do
      {:ok, [struct], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
           embedded_schema "my_schema" do
             field :first_name, :string
             field :last_name, :string
           end
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :definition

      expected =
        ~q[
        embedded_schema "my_schema" do
            field :first_name, :string
            field :last_name, :string
          end
        ]
        |> String.trim()

      assert decorate(doc, struct.range) =~ ~q[«embedded_schema "my_schema" do»]
      assert extract(doc, struct.block_range) =~ expected
    end
  end

  describe "finds referenced to schemas defined with embeds_one" do
    test "ignores a schema reference" do
      {:ok, [struct_def], _doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
            schema "my_schema" do
              embeds_one :friend, Friend
           end
        end
        ]
        |> index()

      assert struct_def.subject == MySchema
    end

    test "when defined inline" do
      {:ok, [_struct_def, schema_definition], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
            schema "my_schema" do
              embeds_one :child, Child do
                field :first_name, :string
              end
           end
        end
        ]
        |> index()

      assert schema_definition.type == :struct
      assert schema_definition.subtype == :definition
      assert schema_definition.subject == MySchema.Child

      expected = ~q[
      embeds_one :child, Child do
             field :first_name, :string
           end
      ]t
      assert decorate(doc, schema_definition.range) =~ ~q[embeds_one :child, «Child» do]
      assert extract(doc, schema_definition.block_range) =~ expected
    end
  end

  describe "finds schemas defined with embeds_many" do
    test "ignores a schema reference" do
      {:ok, [struct_def], _doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
            schema "my_schema" do
              embeds_many :friend, Friend
           end
        end
        ]
        |> index()

      assert struct_def.subject == MySchema
    end

    test "when defined inline" do
      {:ok, [_struct_def, schema_definition], doc} =
        ~q[
         defmodule MySchema do
           use Ecto.Schema
            schema "my_schema" do
              embeds_many :child, Child do
                field :first_name, :string
              end
           end
        end
        ]
        |> index()

      assert schema_definition.type == :struct
      assert schema_definition.subtype == :definition
      assert schema_definition.subject == MySchema.Child

      expected = ~q[
      embeds_many :child, Child do
             field :first_name, :string
           end
      ]t
      assert decorate(doc, schema_definition.range) =~ ~q[embeds_many :child, «Child» do]
      assert extract(doc, schema_definition.block_range) =~ expected
    end
  end

  describe "recovers from invalid code" do
    test "with syntax errors" do
      assert {:ok, [], _doc} =
               ~q[
                defmodule MySchema do
                  use Ecto.Schema
                   schema "my_schema" do
                     field :first_name, :string
                     field :last_name, :string
                end
                ]
               |> index()
    end
  end
end
