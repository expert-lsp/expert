defmodule Engine.CodeMod.Rename.Module.DiffTest do
  use ExUnit.Case, async: true

  alias Engine.CodeMod.Rename.Module.Diff

  describe "diff/2" do
    test "returns the local module pair if only the local name is changed" do
      assert Diff.diff("A.B.C", "A.B.D") == {"C", "D"}
    end

    test "returns the local module pair even if the part of local name is changed" do
      assert Diff.diff("A.B.CD", "A.B.CC") == {"CD", "CC"}
    end

    test "returns the suffix when extending the middle part" do
      assert Diff.diff("Foo.Bar", "Foo.Baz.Bar") == {"Bar", "Baz.Bar"}
    end

    test "returns the suffix if the middle part is removed" do
      assert Diff.diff("Foo.Baz.Bar", "Foo.Bar") == {"Baz.Bar", "Bar"}
    end

    test "returns the entire module pair if the change starts from the first module" do
      assert Diff.diff("Foo.Bar", "Foa.Bar") == {"Foo.Bar", "Foa.Bar"}
    end

    test "treats regular expression metacharacters as text" do
      assert Diff.diff("Foo[Bar.Baz", "Foo[Bar.Qux") == {"Baz", "Qux"}
    end
  end
end
