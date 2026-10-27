defmodule Expert.Search.SubjectTest do
  use ExUnit.Case, async: true

  alias Expert.Search.Subject

  test "a module name read from a BEAM gets the subject its atom would" do
    for module <- [
          Foo,
          Foo.Bar.Baz,
          Elixir,
          :lists,
          :cowboy_router,
          :foo@bar,
          :Foo,
          :"foo.bar",
          :"foo bar",
          :"Elixir.foo",
          :"Elixir.Foo Bar",
          :"Elixir.Foo.",
          :"with\"quote"
        ] do
      assert Subject.module(Atom.to_string(module)) == inspect(module)
    end
  end

  test "keys atoms the way they are inspected and strings as they are" do
    assert Subject.key(Foo.Bar) == "Foo.Bar"
    assert Subject.key(:lists) == ":lists"
    assert Subject.key("Foo.Bar.fun/1") == "Foo.Bar.fun/1"
  end
end
