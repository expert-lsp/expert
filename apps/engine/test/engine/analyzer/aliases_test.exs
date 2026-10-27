defmodule Engine.Analyzer.AliasesTest do
  use ExUnit.Case

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.RangeSupport

  alias Engine.Analyzer
  alias Forge.Ast
  alias Forge.Document

  def aliases_at_cursor(text) do
    {position, document} = pop_cursor(text, as: :document)

    document
    |> Ast.analyze()
    |> Analyzer.aliases_at(position)
    |> Map.new(fn {k, v} -> {k |> concat_without_prefix(), v} end)
  end

  defp scope_aliases(text) do
    {position, document} = pop_cursor(text, as: :document)

    aliases =
      document
      |> Ast.analyze()
      |> Ast.Analysis.scopes_at(position)
      |> Enum.flat_map(& &1.aliases)
      |> Map.new(&{&1.as |> concat_without_prefix(), &1})

    {aliases, document}
  end

  # Acts like Module.concat/1 for elixir modules but skips the "Elixir." prefix.
  defp concat_without_prefix(segments) do
    # Used only in tests, atom table growth is not a concern here.
    segments |> Enum.join(".") |> String.to_atom()
  end

  describe "top level aliases" do
    test "a useless alias" do
      aliases =
        ~q[
          alias Foo
          |
        ]
        |> aliases_at_cursor()

      assert aliases[:Foo] == Foo
    end

    test "an alias outside of a module" do
      aliases =
        ~q[
        alias Foo.Bar.Baz
        defmodule Parent do
          |
        end
      ]
        |> aliases_at_cursor()

      assert aliases[:Baz] == Foo.Bar.Baz
    end

    test "an alias inside the body of a module" do
      aliases =
        ~q[
          defmodule Basic do
            alias Foo.Bar
            |
          end
          ]
        |> aliases_at_cursor()

      assert aliases == %{__MODULE__: Basic, Bar: Foo.Bar, Basic: Basic}
    end

    test "an alias using as" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias Foo.Bar, as: FooBar
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:__MODULE__] == TopLevel
      assert aliases[:FooBar] == Foo.Bar
    end

    test "an alias using warn" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias Foo.Bar, warn: false
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Bar] == Foo.Bar
    end

    test "an alias using warn and as" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias Foo.Bar, warn: false, as: FooBar
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:FooBar] == Foo.Bar
    end

    test "multiple aliases off of single alias" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias Foo.{First, Second, Third.Fourth}
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:First] == Foo.First
      assert aliases[:Second] == Foo.Second
      assert aliases[:Fourth] == Foo.Third.Fourth
    end

    test "multiple aliases off of nested alias" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias Foo.Bar.{First, Second, Third.Fourth}
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:First] == Foo.Bar.First
      assert aliases[:Second] == Foo.Bar.Second
      assert aliases[:Fourth] == Foo.Bar.Third.Fourth
    end

    test "aliasing __MODULE__" do
      aliases =
        ~q[
          defmodule Something.Is.Nested do
            alias __MODULE__|

          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Nested] == Something.Is.Nested
    end

    test "multiple aliases leading by current module" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias __MODULE__.{First, Second}
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:First] == TopLevel.First
      assert aliases[:Second] == TopLevel.Second
    end

    test "multiple aliases leading by current module's child" do
      aliases =
        ~q[
          defmodule TopLevel do
            alias __MODULE__.Child.{First, Second}
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:First] == TopLevel.Child.First
      assert aliases[:Second] == TopLevel.Child.Second
    end

    test "aliases expanding other aliases" do
      aliases =
        ~q[
          alias Foo.Bar.Baz
          alias Baz.Quux|
        ]
        |> aliases_at_cursor()

      assert aliases[:Baz] == Foo.Bar.Baz
      assert aliases[:Quux] == Foo.Bar.Baz.Quux
    end

    test "aliases expanding current module" do
      aliases = ~q[
        defmodule TopLevel do
          alias __MODULE__.Foo|
        end
      ] |> aliases_at_cursor()

      assert aliases[:Foo] == TopLevel.Foo
    end

    test "aliases expanding current module using as" do
      aliases = ~q[
        defmodule TopLevel do
          alias __MODULE__.Foo, as: OtherAlias|
        end
      ] |> aliases_at_cursor()

      assert aliases[:OtherAlias] == TopLevel.Foo
    end

    test "can be overridden" do
      aliases =
        ~q[
          alias Foo.Bar.Baz
          alias Other.Baz
          |
        ]
        |> aliases_at_cursor()

      assert aliases[:Baz] == Other.Baz
    end

    test "can be overridden on the same line" do
      aliases =
        ~q[
          alias Foo.Bar.Baz; alias Other.Baz
          |
        ]
        |> aliases_at_cursor()

      assert aliases[:Baz] == Other.Baz
    end

    test "can be accessed before being overridden" do
      aliases =
        ~q[
          alias Foo.Bar.Baz
          |
          alias Other.Baz
        ]
        |> aliases_at_cursor()

      assert aliases[:Baz] == Foo.Bar.Baz
    end

    test "aliases used to define a module" do
      aliases =
        ~q[
          alias Something.Else
          defmodule Else.Other do
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Else] == Something.Else
    end

    test "in a protocol implementation" do
      aliases =
        ~q[
      defimpl MyProtocol, for: Atom do
        |
      end
      ]
        |> aliases_at_cursor()

      assert aliases[:"@protocol"] == MyProtocol
      assert aliases[:"@for"] == Atom
    end

    test "skips unquote-based aliases in quoted blocks" do
      aliases =
        ~q<
          defmodule TopLevel do
            defmacro __using__(module) do
              quote do
                alias unquote(module).Helpers|
              end
            end
          end
        >
        |> aliases_at_cursor()

      assert is_map(aliases)
      refute Map.has_key?(aliases, :Helpers)
    end
  end

  describe "alias ranges" do
    test "for a simple alias" do
      {aliases, doc} =
        ~q[
          defmodule Parent do
            alias Foo.Bar.Baz|
          end
        ]
        |> scope_aliases()

      assert decorate(doc, aliases[:Baz].range) =~ "  «alias Foo.Bar.Baz»"
    end

    test "for a multiple alias on one line" do
      {aliases, doc} =
        ~q[
            defmodule Parent do
              alias Foo.Bar.{Baz, Quux}|
            end
        ]
        |> scope_aliases()

      assert decorate(doc, aliases[:Baz].range) =~ "  «alias Foo.Bar.{Baz, Quux}»"
      assert decorate(doc, aliases[:Quux].range) =~ "  «alias Foo.Bar.{Baz, Quux}»"
    end

    test "for a multiple alias on multiple lines" do
      {aliases, doc} =
        ~q[
            defmodule Parent do
              alias Foo.Bar.{
                Baz,
                Quux,
                Other
            }|
            end
        ]
        |> scope_aliases()

      for name <- [:Baz, :Quux, :Other] do
        assert decorate(doc, aliases[name].range) =~
                 "  «alias Foo.Bar.{\n    Baz,\n    Quux,\n    Other\n}»"
      end
    end

    def column_after_do(%Document{} = doc, line) do
      with {:ok, text} <- Document.fetch_text_at(doc, line),
           {:ok, column} <- find_do_position(text, 0) do
        column + 2
      else
        _ ->
          :not_found
      end
    end

    def find_do_position("do" <> _, position) do
      {:ok, position}
    end

    def find_do_position(<<_c::utf8, rest::binary>>, position) do
      find_do_position(rest, position + 1)
    end

    def find_do_position(<<>>, _) do
      :not_found
    end

    test "__MODULE__ implicit aliases don't have a visible range" do
      {aliases, doc} =
        ~q[
          defmodule MyModule do
          |
          end
        ]
        |> scope_aliases()

      module_range = aliases[:__MODULE__].range

      refute aliases[:__MODULE__].explicit?
      assert module_range.start.line == 1
      assert module_range.start.character == column_after_do(doc, 1)
      assert module_range.start == module_range.end
    end

    test "implicit parent alias doesn't have a range" do
      {aliases, doc} =
        ~q[
          defmodule Parent do
            defmodule Child do
             |
            end
          end
        ]
        |> scope_aliases()

      parent_range = aliases[:Parent].range

      refute aliases[:Parent].explicit?
      assert parent_range.start.line == 1
      assert parent_range.start.character == column_after_do(doc, 1)
      assert parent_range.start == parent_range.end
    end

    test "protocol implicit aliases doesn't have a visible range" do
      {aliases, doc} =
        ~q[
          defimpl MyThing, for: MyProtocol do
           |
          end
        ]
        |> scope_aliases()

      # the implicit aliases don't have any text in their range

      for_range = aliases[:"@for"].range
      refute aliases[:"@for"].explicit?
      assert for_range.start.line == 1
      assert for_range.start.character == column_after_do(doc, 1)
      assert for_range.start == for_range.end

      protocol_range = aliases[:"@protocol"].range
      refute aliases[:"@protocol"].explicit?
      assert protocol_range.start.line == 1
      assert protocol_range.start.character == column_after_do(doc, 1)
      assert protocol_range.start == protocol_range.end
    end
  end

  describe "nested modules" do
    test "no aliases are defined for modules with dots" do
      aliases =
        ~q[
          defmodule GrandParent.Parent.Child do
           |
          end
        ]
        |> aliases_at_cursor()

      refute Map.has_key?(aliases, :Child)
    end

    test "with children get their parents name" do
      aliases =
        ~q[
          defmodule Grandparent.Parent do
            defmodule Child do
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Child] == Grandparent.Parent.Child
      assert aliases[:__MODULE__] == Grandparent.Parent.Child
    end

    test "with a child that has an explicit parent" do
      aliases =
        ~q[
          defmodule Parent do
            defmodule __MODULE__.Child do
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:__MODULE__] == Parent.Child
    end

    test "doted parent and child" do
      aliases =
        ~q[
          defmodule Parent.Foo do
            defmodule Bar.Baz do
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:"Bar.Baz"] == Parent.Foo.Bar.Baz
      assert aliases[:"Parent.Foo"] == Parent.Foo
      assert aliases[:__MODULE__] == Parent.Foo.Bar.Baz
    end
  end

  describe "alias scopes" do
    test "aliases are removed when leaving a module" do
      aliases =
        ~q[
          defmodule Basic do
            alias Foo.Bar
          end|
        ]
        |> aliases_at_cursor()

      assert aliases == %{Basic: Basic}
    end

    test "aliases inside of nested modules" do
      aliases =
        ~q[
          defmodule Parent do
            alias Foo.Grandparent

            defmodule Child do
              alias Foo.Something
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Grandparent] == Foo.Grandparent
      assert aliases[:Something] == Foo.Something
      assert aliases[:__MODULE__] == Parent.Child
      assert aliases[:Child] == Parent.Child
    end

    test "multiple nested module are aliased after definition" do
      aliases =
        ~q[
          defmodule Parent do
            alias Foo.Grandparent

            defmodule Child do
              alias Foo.Something
            end

            defmodule AnotherChild do
              alias Foo.Something
            end
            |
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:AnotherChild] == Parent.AnotherChild
      assert aliases[:Child] == Parent.Child
    end

    test "an alias defined in a named function" do
      aliases =
        ~q[
          defmodule Parent do
            def fun do
              alias Foo.Parent
            |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Parent] == Foo.Parent
    end

    test "an alias defined in a named function doesn't leak" do
      aliases =
        ~q[
          defmodule Parent do
            def fun do
              alias Foo.Parent
            end|
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Parent] == Parent
    end

    test "an alias defined in a private named function" do
      aliases =
        ~q[
          defmodule Parent do
            defp fun do
              alias Foo.Parent
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Parent] == Foo.Parent
    end

    test "an alias defined in a private named function doesn't leak" do
      aliases =
        ~q[
          defmodule Parent do
            defp fun do
              alias Foo.InFun
            end|
          end
        ]
        |> aliases_at_cursor()

      refute aliases[:InFun]
    end

    test "an alias defined in a DSL" do
      aliases =
        ~q[
          defmodule Parent do
             my_dsl do
              alias Foo.Parent
              |
            end
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Parent] == Foo.Parent
    end

    test "an alias defined in a DSL does not leak" do
      aliases =
        ~q[
          defmodule Parent do
             my_dsl do
              alias Foo.InDSL
             end
             |
          end
        ]
        |> aliases_at_cursor()

      refute aliases[InDsl]
    end

    test "an alias defined in an if statement" do
      aliases =
        ~q[
        if test() do
          alias Foo.Something
          |
        end
        ]
        |> aliases_at_cursor()

      assert aliases[:Something]
    end

    test "an alias defined in an if statement does not leak" do
      aliases =
        ~q[
        if test() do
          alias Foo.Something
        end
        |
        ]
        |> aliases_at_cursor()

      refute aliases[:Something]
    end

    test "an alias defined in an cond statement" do
      aliases =
        ~q[
        cond do
          something() ->
            alias Foo.Something
            |Else
          true ->
            :ok
        end
        ]
        |> aliases_at_cursor()

      assert aliases[:Something]
    end

    test "an alias defined in an cond statement shouldn't leak" do
      aliases =
        ~q[
        cond do
          something() ->
            alias Foo.Something
          true ->
            |
            :ok
        end
        ]
        |> aliases_at_cursor()

      refute aliases[:Something]

      aliases =
        ~q[
        cond do
          something() ->
            alias Foo.Something
          true ->
            :ok
        end
        |
        ]
        |> aliases_at_cursor()

      refute aliases[:Something]
    end

    test "an alias defined in an with statement" do
      aliases =
        ~q[
        with {:ok, val} <- some_function() do
        alias Foo.Something
        |
        end
        ]
        |> aliases_at_cursor()

      assert aliases[:Something]
    end

    test "an alias defined in an with statement shouldn't leak" do
      aliases =
        ~q[
        with {:ok, val} <- some_function() do
        alias Foo.Something
        end
        |
        ]
        |> aliases_at_cursor()

      refute aliases[:Something]
    end

    test "sibling modules with nested blocks" do
      aliases =
        ~q[
          defmodule First do
            defstuff do
              field :x
            end
          end

          defmodule Second do
            defstuff do
              field :y
            end
          end
          |
        ]
        |> aliases_at_cursor()

      assert aliases[:First] == First
      assert aliases[:Second] == Second
    end

    test "an alias defined in a anonymous function" do
      aliases =
        ~q[
          fn x ->
            alias Foo.Bar
            Bar|
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Bar] == Foo.Bar
    end

    test "an alias defined in a anonymous function doesn't leak" do
      aliases =
        ~q[
          fn
            x ->
              alias Foo.Bar
              Bar.bar(x)
            y ->
              alias Baz.Buzz
              |Buzz
          end
        ]
        |> aliases_at_cursor()

      assert aliases[:Buzz] == Baz.Buzz
      refute aliases[:Bar]
    end
  end
end
