defmodule Expert.Search.Indexer.Extractors.ModuleTest do
  use Expert.Test.ExtractorCase

  alias Some.Other.Thing.Util

  def index(source) do
    do_index(source, &(&1.type == :module))
  end

  describe "indexing modules" do
    test "it doesn't confuse a list of atoms for a module" do
      {:ok, [module], _} =
        ~q(
          defmodule Root do
            @attr [:Some, :Other, :Module]
          end
        )
        |> index()

      assert module.type == :module
      assert module.subject == Root
    end

    test "indexes a flat module with no aliases" do
      {:ok, [entry], doc} =
        ~q[
        defmodule Simple do
        end
        ]
        |> index()

      assert entry.type == :module
      assert entry.block_id == :root
      assert entry.subject == Simple
      assert decorate(doc, entry.range) =~ "defmodule «Simple» do"
    end

    test "indexes a flat module with a dotted name" do
      {:ok, [entry], doc} =
        ~q[
        defmodule Simple.Module.Path do
        end
        ]
        |> index()

      assert entry.subject == Simple.Module.Path
      assert entry.type == :module
      assert entry.block_id == :root
      assert decorate(doc, entry.range) =~ "defmodule «Simple.Module.Path» do"
    end

    test "indexes a flat module with an aliased name" do
      {:ok, [_alias, entry], doc} =
        ~q[
        alias Something.Else
        defmodule Else.Other do
        end
      ]
        |> index()

      assert entry.subject == Something.Else.Other
      assert decorate(doc, entry.range) == "defmodule «Else.Other» do"
    end

    test "can detect an erlang module" do
      {:ok, [module_def, erlang_module], doc} =
        ~q[
        defmodule Root do
          @something :timer
        end
      ]
        |> index()

      assert erlang_module.type == :module
      assert erlang_module.block_id == module_def.id
      assert erlang_module.subject == :timer
      assert decorate(doc, erlang_module.range) =~ "  @something «:timer»"
    end

    test "can detect a module reference in a module attribute" do
      {:ok, [module_def, attribute], doc} =
        ~q[
        defmodule Root do
          @attr Some.Other.Module
        end
      ]
        |> index()

      assert attribute.type == :module
      assert attribute.block_id == module_def.id
      assert attribute.subject == Some.Other.Module
      assert decorate(doc, attribute.range) =~ "  @attr «Some.Other.Module»"
    end

    test "can detect __MODULE__ in a function" do
      {:ok, [_module_def, module_ref], doc} =
        ~q[
        defmodule Root do
          def something do
           __MODULE__
          end
        end
        ]
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Root
      assert decorate(doc, module_ref.range) =~ "   «__MODULE__»"
    end

    test "can detect a module reference on the left side of a pattern match" do
      {:ok, [_module_def, module_ref], doc} =
        ~q[
        defmodule Root do
          def my_fn(arg) do
            Some.Module = arg
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "«Some.Module» = arg"
    end

    test "can detect an aliased module reference on the left side of a pattern match" do
      {:ok, [_module_def, _alias, module_ref], doc} =
        ~q[
        defmodule Root do
          alias Some.Other.Thing
          def my_fn(arg) do
            Thing.Util = arg
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Util
      assert decorate(doc, module_ref.range) =~ "    «Thing.Util» = arg"
    end

    test "can detect a module reference in a nested alias" do
      {:ok, [_top_level, _foo, _first, second, fourth], doc} = ~q[
        defmodule TopLevel do
          alias Foo.{
            First,
            Second,
            Third.Fourth
          }
        end] |> index()

      assert second.subject == Foo.Second
      assert decorate(doc, second.range) == "    «Second»,"

      assert fourth.subject == Foo.Third.Fourth
      assert decorate(doc, fourth.range) == "    «Third.Fourth»"
    end

    test "can detect a module reference on the right side of a pattern match" do
      {:ok, [_module, module_ref], doc} =
        ~q[
        defmodule Root do
          def my_fn(arg) do
            arg = Some.Module
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "arg = «Some.Module»"
    end

    test "can detect an aliased module reference on the right side of a pattern match" do
      {:ok, [_module_def, _alias, module_ref], doc} =
        ~q[
        defmodule Root do
          alias Some.Other.Thing
          def my_fn(arg) do
            arg = Thing.Util
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Util
      assert decorate(doc, module_ref.range) =~ "    arg = «Thing.Util»"
    end

    test "can detect a module reference in a remote call" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule RemoteCall do
          def my_fn do
            Some.Module.function()
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "  «Some.Module».function()"
    end

    test "can detect a module reference in a remote captured function" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule Capture do
            def my_fn do
              &Some.Module.function/1
            end
          end
        ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "  &«Some.Module».function/1"
    end

    test "can detect a module reference in a remote captured function with multiple arities" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule Capture do
            def my_fn do
              &Some.Module.function(&1, 1)
            end
          end
        ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "  &«Some.Module».function(&1, 1)"
    end

    test "can detect a module reference in an aliased remote captured function" do
      {:ok, [_module, _alias, _aliased, module_ref], doc} = ~q[
          defmodule Capture do
            alias First.Second, as: Third
            def my_fn do
              &Third.function/1
            end
          end
        ]t |> index()

      assert module_ref.type == :module
      assert module_ref.subject == First.Second
      assert decorate(doc, module_ref.range) =~ "  &«Third».function/1"
    end

    test "can detect a module reference in a function call's arguments" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule FunCallArgs do
          def my_fn do
            function(Some.Module)
          end

          def function(_) do
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "  function(«Some.Module»)"
    end

    test "can detect a module reference in a function's pattern match arguments" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule FunCallArgs do
          def my_fn(arg = Some.Module) do
            arg
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "def my_fn(arg = «Some.Module»)"
    end

    test "can detect a module reference in default parameters" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule FunCallArgs do
          def my_fn(module \\ Some.Module) do
            module.foo()
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ ~S[def my_fn(module \\ «Some.Module»)]
    end

    test "can detect a module reference in map keys" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule FunCallArgs do
          def my_fn do
            %{Some.Module => 1}
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "%{«Some.Module» => 1}"
    end

    test "can detect a module reference in map values" do
      {:ok, [_module, module_ref], doc} =
        ~q[
          defmodule FunCallArgs do
          def my_fn do
            %{invalid: Some.Module}
          end
        end
      ]t
        |> index()

      assert module_ref.type == :module
      assert module_ref.subject == Some.Module
      assert decorate(doc, module_ref.range) =~ "%{invalid: «Some.Module»}"
    end

    test "can detect a module reference in an anonymous function call" do
      {:ok, [parent, ref], doc} =
        ~q[
        defmodule Parent do
          def outer_fn do
            fn ->
              Ref.To.Something
            end
          end
        end
      ]
        |> index()

      assert ref.type == :module
      assert ref.subject == Ref.To.Something
      refute ref.block_id == parent.id
      assert decorate(doc, ref.range) =~ "      «Ref.To.Something»"
    end

    test "can detect a @protocol module reference" do
      {:ok, [protocol_def, protocol_ref, for_ref, proto_module_attr], doc} =
        ~q[
          defimpl MyProtocol, for: Atom do
            def something do
             @protocol.Something
            end
          end
        ]
        |> index()

      assert protocol_def.type == :module
      assert protocol_def.subtype == :definition
      assert protocol_def.subject == MyProtocol.Atom
      assert decorate(doc, protocol_def.range) == "«defimpl MyProtocol, for: Atom do»"

      assert protocol_ref.type == :module
      assert protocol_ref.subtype == :reference
      assert protocol_ref.subject == MyProtocol
      assert decorate(doc, protocol_ref.range) == "defimpl «MyProtocol», for: Atom do"

      assert for_ref.type == :module
      assert for_ref.subtype == :reference
      assert for_ref.subject == Atom
      assert decorate(doc, for_ref.range) == "defimpl MyProtocol, for: «Atom» do"

      assert proto_module_attr.type == :module
      assert proto_module_attr.subtype == :reference
      assert proto_module_attr.subject == MyProtocol.Something
      assert decorate(doc, proto_module_attr.range) == "   «@protocol.Something»"
    end

    test "can detect an @for module reference" do
      {:ok, [_, _, _, for_module_attr], doc} =
        ~q[
          defimpl MyProtocol, for: DataStructure do
            def something do
             @for.Something
            end
          end
        ]
        |> index()

      assert for_module_attr.type == :module
      assert for_module_attr.subtype == :reference
      assert for_module_attr.subject == DataStructure.Something
      assert decorate(doc, for_module_attr.range) == "   «@for.Something»"
    end
  end

  describe "multiple modules in one document" do
    test "have different refs" do
      {:ok, [first, second], _} =
        ~q[
          defmodule First do
          end

          defmodule Second do
          end
        ]
        |> index()

      assert first.block_id == :root
      assert first.type == :module
      assert first.subtype == :definition
      assert first.subject == First

      assert second.block_id == :root
      assert second.type == :module
      assert second.subtype == :definition
      assert second.subject == Second

      assert second.id != first.id
    end

    test "aren't nested" do
      {:ok, [first, second, third, fourth], _} =
        ~q[
          defmodule A.B.C do
            defstruct do
              field(:ok, :boolean)
            end
          end

          defmodule D.E.F do
            defstruct do
              field(:ok, :boolean)
            end
          end

          defmodule G.H.I do
            defstruct do
              field(:ok, :boolean)
            end
          end

          defmodule J.K.L do
            defstruct do
              field(:ok, :boolean)
            end
          end
        ]
        |> index()

      assert first.subject == A.B.C
      assert second.subject == D.E.F
      assert third.subject == G.H.I
      assert fourth.subject == J.K.L
    end
  end

  describe "nested modules" do
    test "have a parent/child relationship" do
      {:ok, [parent, child], _} =
        ~q[
        defmodule Parent do
          defmodule Child do
          end
        end
      ]
        |> index()

      assert parent.block_id == :root
      assert parent.type == :module
      assert parent.subtype == :definition

      assert child.block_id == parent.id
      assert child.type == :module
      assert child.subtype == :definition
    end

    test "Have aliases resolved correctly" do
      {:ok, [_parent, _parent_alias, child, child_alias], _} =
        ~q[
        defmodule Parent do
          alias Something.Else

          defmodule Child do
            alias Else.Other
          end
        end
      ]
        |> index()

      assert child_alias.block_id == child.id
      assert child_alias.type == :module
      assert child_alias.subtype == :reference
      assert child_alias.subject == Something.Else.Other
    end

    test "works with __MODULE__" do
      {:ok, [parent, child], _} =
        ~q[
          defmodule Parent do
            defmodule __MODULE__.Child do
            end
          end
        ]
        |> index()

      assert parent.block_id == :root
      assert parent.type == :module
      assert parent.subtype == :definition

      assert child.block_id == parent.id
      assert child.type == :module
      assert child.subtype == :definition
    end

    test "works with __MODULE__ alias concatenations" do
      {:ok, [_, child], _} =
        ~q[
        defmodule Parent do
          @child_module __MODULE__.Child
        end
        ]
        |> index()

      assert child.type == :module
      assert child.subtype == :reference
      assert child.subject == Parent.Child
    end
  end
end
