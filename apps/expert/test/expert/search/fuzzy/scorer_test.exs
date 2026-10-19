defmodule Expert.Search.Fuzzy.ScorerTest do
  use ExUnit.Case

  alias Expert.Search.Fuzzy.Scorer

  describe "matching" do
    test "fails if one character doesn't appear" do
      assert {false, _} = Scorer.score("Enum", "Enuq")
    end

    test "fails if no characters appear" do
      assert {false, _} = Scorer.score("Enum", "pq")
    end

    test "a match at the beginning of the string is a match" do
      assert {true, _} = Scorer.score("Enum", "En")
    end

    test "a pattern that contains characters in the string is a match" do
      assert {true, _} = Scorer.score("Enumerable", "Eml")
    end

    test "a pattern that contains letters at the start and end is a match" do
      assert {true, _} = Scorer.score("Baz", "bz")
    end

    test "patterns are case insensitive" do
      assert {true, _} = Scorer.score("Enum", "enu")
    end
  end

  defp score_and_sort(subjects, pattern) do
    Enum.sort_by(
      subjects,
      fn subject ->
        {_, score} = Scorer.score(subject, pattern)
        score
      end,
      :desc
    )
  end

  describe "matching heuristics" do
    test "more complete matches are boosted" do
      results =
        score_and_sort(
          ~w(Forge.Document.Range Something.Else.Expert.Other.Type.Document.Thing Forge.Document),
          "Forge.Document"
        )

      assert results ==
               ~w(Forge.Document Forge.Document.Range Something.Else.Expert.Other.Type.Document.Thing)
    end

    test "matches at the beginning of the string are boosted" do
      results =
        score_and_sort(
          ~w(Something.Else.Document Something.Document Document),
          "Document"
        )

      assert results == ~w(Document Something.Document Something.Else.Document)
    end

    test "patterns that match consecutive characters are boosted" do
      results = score_and_sort(~w(axxxbxxxcxxxdxxx axxbxxcxxdxx axbxcxdx abcd), "abcd")
      assert results == ~w(abcd axbxcxdx axxbxxcxxdxx axxxbxxxcxxxdxxx)
    end

    test "patterns that match camel case are boosted" do
      results =
        score_and_sort(
          ~w(lotsofcamelcase LotsofcamelCase LotsofCamelCase LotsOfCamelCase),
          "LotsOfCamelCase"
        )

      assert results == ~w(LotsOfCamelCase LotsofCamelCase LotsofcamelCase lotsofcamelcase)
    end

    test "matches at the end of a module are boosted" do
      results =
        score_and_sort(
          ~w(First.Third.Second Third.First.Second First.Second.Third),
          "Third"
        )

      assert ["First.Second.Third" | _] = results
    end

    test "tail matches are boosted" do
      results =
        score_and_sort(~w(create_user save_user Foo.Bar.Baz.Demo.Accounts.LiveDemo.User), "User")

      assert ["Foo.Bar.Baz.Demo.Accounts.LiveDemo.User" | _] = results
    end
  end

  describe "preprocess/1" do
    test "handles strings without dots" do
      preprocessed = Scorer.preprocess("SimpleName")
      assert {true, _} = Scorer.score(preprocessed, "simple")
    end

    test "handles empty string" do
      preprocessed = Scorer.preprocess("")
      assert {false, _} = Scorer.score(preprocessed, "a")
    end

    test "handles terms via inspect" do
      preprocessed = Scorer.preprocess(My.Module.Name)
      assert {true, _} = Scorer.score(preprocessed, "name")
    end
  end
end
