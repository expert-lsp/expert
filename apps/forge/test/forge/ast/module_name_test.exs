defmodule Forge.Ast.ModuleNameTest do
  use ExUnit.Case, async: true

  alias Forge.Ast

  test "names atoms as inspect does" do
    loaded = for {name, _, _} <- :code.all_available(), do: List.to_atom(name)

    awkward = [
      Elixir,
      Elixir.Elixir,
      Elixir.Elixir.Foo,
      Foo,
      Foo.Bar2,
      Foo.Bar_Baz,
      :"Elixir.Foo.bar",
      :"Elixir.Foo.Bar-Baz",
      :"Elixir.Foo..Bar",
      :"Elixir.Foo.",
      :"Elixir.",
      :"Elixir.2Foo",
      :"Elixir.Foo Bar",
      :"Elixir.Foo.Bär",
      :erlang,
      :"foo bar",
      :foo@bar,
      nil,
      true,
      :Foo
    ]

    for atom <- awkward ++ loaded do
      assert Ast.Module.name(atom) == inspect(atom), inspect(atom)
    end

    assert length(loaded) > 1_000
  end
end
