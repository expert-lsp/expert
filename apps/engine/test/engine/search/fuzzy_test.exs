defmodule Engine.Search.FuzzyTest do
  use ExUnit.Case

  import Engine.Test.Entry.Builder

  alias Engine.Search.Fuzzy

  setup do
    entries = [
      definition(subject: Enum),
      definition(subject: Foo.Bar),
      definition(subject: Bar.Baz)
    ]

    fuzzy = Fuzzy.from_entries(entries)
    {:ok, fuzzy: fuzzy, entries: entries}
  end

  def lookup(entities, id) do
    Enum.find(entities, &(&1.id == id))
  end

  describe "housekeeping" do
    test "it can add an entry", %{fuzzy: fuzzy} do
      refute Fuzzy.has_subject?(fuzzy, Other)
      entry = definition(subject: Other)

      fuzzy = Fuzzy.add(fuzzy, entry)

      assert Fuzzy.has_subject?(fuzzy, Other)
    end

    test "it can add multiple entries at once", %{fuzzy: fuzzy} do
      refute Fuzzy.has_subject?(fuzzy, Stinky)
      refute Fuzzy.has_subject?(fuzzy, Pants)

      entries = [
        definition(subject: Stinky),
        definition(subject: Pants)
      ]

      fuzzy = Fuzzy.add(fuzzy, entries)

      assert Fuzzy.has_subject?(fuzzy, Stinky)
      assert Fuzzy.has_subject?(fuzzy, Pants)
    end

    test "a value can be removed", %{fuzzy: fuzzy, entries: [to_remove | _]} do
      assert Fuzzy.has_subject?(fuzzy, to_remove.subject)
      fuzzy = Fuzzy.drop_values(fuzzy, [to_remove.id])

      refute Fuzzy.has_subject?(fuzzy, to_remove.subject)
    end

    test "removing a non-existent value is a no-op", %{fuzzy: fuzzy} do
      assert fuzzy == Fuzzy.drop_values(fuzzy, [:does, :not, :exist])
    end
  end

  describe "match/2" do
    test "fuzzy searching can find prefixes", %{fuzzy: fuzzy, entries: entries} do
      assert [id] = Fuzzy.match(fuzzy, "Enum")
      entry = lookup(entries, id)
      assert entry.subject == Enum
    end

    test "fuzzy matching is applied", %{fuzzy: fuzzy} do
      assert [_, _] = Fuzzy.match(fuzzy, "br")
    end
  end
end
