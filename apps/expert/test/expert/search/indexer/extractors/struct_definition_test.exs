defmodule Expert.Search.Indexer.Extractors.StructDefinitionTest do
  use Expert.Test.ExtractorCase

  alias Forge.Search.Subject

  def index(source) do
    do_index(source, fn entry ->
      entry.type == :struct and entry.subtype == :definition
    end)
  end

  test "it should find a module that defines a struct via a list of atoms" do
    {:ok, [struct], doc} =
      ~q(
        defmodule Root do
         defstruct [:name, :value]
        end
        )
      |> index()

    assert struct.type == :struct
    assert struct.subtype == :definition
    assert struct.subject == Subject.module(Root)

    assert decorate(doc, struct.range) =~ "«defstruct [:name, :value]»"
  end

  test "it highlights multiple line definitions" do
    {:ok, [struct], doc} =
      ~q(
        defmodule Root do
         defstruct [
          :name,
          :value,
          :other
         ]
        end
        )
      |> index()

    expected =
      """
      «defstruct [
        :name,
        :value,
        :other
       ]»
      """
      |> String.trim()

    assert decorate(doc, struct.range) =~ expected
  end

  test "it should find a module that defines a struct via a keyword list" do
    {:ok, [struct], doc} =
      ~q(
        defmodule Root do
         defstruct [name: nil, cost: 0]
        end
        )
      |> index()

    assert struct.type == :struct
    assert struct.subtype == :definition
    assert struct.subject == Subject.module(Root)

    assert decorate(doc, struct.range) =~ "«defstruct [name: nil, cost: 0]»"
  end

  test "it finds struct definitions in nested modules" do
    {:ok, [child, parent], doc} =
      ~q(
        defmodule Parent do
          defmodule Child do
            defstruct [:parent, :height]
          end
          defstruct [name: nil, cost: 0]
        end
        )
      |> index()

    assert child.type == :struct
    assert child.subtype == :definition
    assert child.subject == Subject.module(Parent.Child)
    assert decorate(doc, child.range) =~ "«defstruct [:parent, :height]"

    assert parent.type == :struct
    assert parent.subtype == :definition
    assert parent.subject == Subject.module(Parent)
    assert decorate(doc, parent.range) =~ "«defstruct [name: nil, cost: 0]"
  end
end
