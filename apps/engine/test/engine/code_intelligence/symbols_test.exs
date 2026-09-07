defmodule Engine.CodeIntelligence.SymbolsTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.RangeSupport

  alias Engine.CodeIntelligence.Symbols
  alias Engine.Search.Indexer.Extractors
  alias Engine.Search.Indexer.Source
  alias Forge.CodeIntelligence.Symbols.Document

  setup do
    start_supervised!(Engine.ApplicationCache)
    :ok
  end

  def document_symbols(code) do
    doc = Forge.Document.new("file:///file.ex", code, 1)
    symbols = Symbols.for_document(doc)
    {symbols, doc}
  end

  def workspace_symbols(code) do
    doc = Forge.Document.new("file:///file.ex", code, 1)
    uri = Forge.Document.Path.to_uri(doc.path)

    {:ok, entries} =
      Source.index_document(doc, [
        Extractors.ExUnit,
        Extractors.FunctionDefinition,
        Extractors.FunctionReference,
        Extractors.Module,
        Extractors.ModuleAttribute,
        Extractors.StructReference
      ])

    entries = Enum.reject(entries, &(&1.type == :metadata))
    patch(Engine, :get_project, %Forge.Project{})

    patch(Engine.ManagerApi, :search_store_all, fn _project, [subtype: :definition] ->
      {:ok, entries}
    end)

    symbols = Symbols.for_workspace("")
    {symbols, doc, uri}
  end

  defp in_a_module(code) do
    """
    defmodule Parent do
      #{code}
    end
    """
  end

  describe "document symbols" do
    test "a top level module is found" do
      {[%Document{} = module], doc} =
        ~q[
        defmodule MyModule do
        end
        ]
        |> document_symbols()

      assert decorate(doc, module.detail_range) =~ "defmodule «MyModule» do"
      assert module.name == "MyModule"
      assert module.type == :module
      assert module.children == []
    end

    test "multiple top-level modules are found" do
      {[first, second], doc} =
        ~q[
        defmodule First do
        end

        defmodule Second do
        end
        ]
        |> document_symbols()

      assert decorate(doc, first.detail_range) =~ "defmodule «First» do"
      assert first.name == "First"
      assert first.type == :module

      assert decorate(doc, second.detail_range) =~ "defmodule «Second» do"
      assert second.name == "Second"
      assert second.type == :module
    end

    test "nested modules are found" do
      {[outer], doc} =
        ~q[
        defmodule Outer do
          defmodule Inner do
            defmodule Innerinner do
            end
          end
        end
        ]
        |> document_symbols()

      assert decorate(doc, outer.detail_range) =~ "defmodule «Outer» do"
      assert outer.name == "Outer"
      assert outer.type == :module

      assert [inner] = outer.children
      assert decorate(doc, inner.detail_range) =~ "defmodule «Inner» do"
      assert inner.name == "Outer.Inner"
      assert inner.type == :module

      assert [inner_inner] = inner.children
      assert decorate(doc, inner_inner.detail_range) =~ "defmodule «Innerinner» do"
      assert inner_inner.name == "Outer.Inner.Innerinner"
      assert inner_inner.type == :module
    end

    test "module attribute definitions are found" do
      {[module], doc} =
        ~q[
        defmodule Module do
          @first 3
          @second 4
        end
        ]
        |> document_symbols()

      assert [first, second] = module.children
      assert decorate(doc, first.detail_range) =~ "  «@first 3»"
      assert first.name == "@first"

      assert decorate(doc, second.detail_range) =~ "  «@second 4»"
      assert second.name == "@second"
    end

    test "in-progress module attributes are skipped" do
      {[module], doc} =
        ~q[
        defmodule Module do
          @
          @callback foo() :: :ok
        end
        ]
        |> document_symbols()

      assert module.type == :module
      assert module.name == "Module"

      [callback] = module.children

      assert callback.type == :module_attribute
      assert callback.name == "@callback"
      assert callback.range == callback.detail_range
      assert decorate(doc, callback.range) =~ "«@callback foo() :: :ok»"
    end

    test "module attribute references are skipped" do
      {[module], _doc} =
        ~q[
         defmodule Parent do
           @attr 3
           def my_fun() do
            @attr
           end
          end
        ]
        |> document_symbols()

      [_attr_def, function_def] = module.children
      [] = function_def.children
    end

    test "public function definitions are found" do
      {[module], doc} =
        ~q[
        defmodule Module do
          def my_fn do
          end
        end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert decorate(doc, function.detail_range) =~ " def «my_fn» do"
    end

    test "public functions created with defdelegate are found" do
      {[module], doc} =
        ~q[
          defmodule Module do
            defdelegate map(enumerable, func), to: Enum
          end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert function.type == {:function, :delegate}

      assert decorate(doc, function.detail_range) =~
               "  defdelegate «map(enumerable, func)», to: Enum"
    end

    test "public functions created with defdelegate using as are found" do
      {[module], doc} =
        ~q[
          defmodule Module do
            defdelegate collect(enumerable, func), to: Enum, as: :map
          end
        ]
        |> document_symbols()

      assert [function] = module.children

      assert decorate(doc, function.detail_range) =~
               "  defdelegate «collect(enumerable, func)», to: Enum, as: :map"
    end

    test "private function definitions are found" do
      {[module], doc} =
        ~q[
        defmodule Module do
          defp my_fn do
          end
        end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert decorate(doc, function.detail_range) =~ " defp «my_fn» do"
      assert function.name == "defp my_fn"
    end

    test "multiple arity functions are grouped" do
      {[module], doc} =
        ~q[
        defmodule Module do
          def function_arity(:foo), do: :ok
          def function_arity(:bar), do: :ok
          def function_arity(:baz), do: :ok
        end
        ]
        |> document_symbols()

      assert [parent] = module.children
      assert parent.name == "def function_arity/1"

      expected_range =
        """
          «def function_arity(:foo), do: :ok
          def function_arity(:bar), do: :ok
          def function_arity(:baz), do: :ok»
        """
        |> String.trim_trailing()

      assert decorate(doc, parent.range) =~ expected_range
      assert [first, second, third] = parent.children

      assert first.name == "function_arity(:foo)"
      assert decorate(doc, first.range) =~ "«def function_arity(:foo), do: :ok»"
      assert decorate(doc, first.detail_range) =~ "def «function_arity(:foo)», do: :ok"

      assert second.name == "function_arity(:bar)"
      assert decorate(doc, second.range) =~ "«def function_arity(:bar), do: :ok»"
      assert decorate(doc, second.detail_range) =~ "def «function_arity(:bar)», do: :ok"

      assert third.name == "function_arity(:baz)"
      assert decorate(doc, third.range) =~ "«def function_arity(:baz), do: :ok»"
      assert decorate(doc, third.detail_range) =~ "def «function_arity(:baz)», do: :ok"
    end

    test "multiple arity private functions are grouped" do
      {[module], doc} =
        ~q[
        defmodule Module do
          defp function_arity(:foo), do: :ok
          defp function_arity(:bar), do: :ok
          defp function_arity(:baz), do: :ok
        end
        ]
        |> document_symbols()

      assert [parent] = module.children
      assert parent.name == "defp function_arity/1"

      expected_range =
        """
          «defp function_arity(:foo), do: :ok
          defp function_arity(:bar), do: :ok
          defp function_arity(:baz), do: :ok»
        """
        |> String.trim_trailing()

      assert decorate(doc, parent.range) =~ expected_range
      assert [first, second, third] = parent.children

      assert first.name == "function_arity(:foo)"
      assert decorate(doc, first.range) =~ "«defp function_arity(:foo), do: :ok»"
      assert decorate(doc, first.detail_range) =~ "defp «function_arity(:foo)», do: :ok"

      assert second.name == "function_arity(:bar)"
      assert decorate(doc, second.range) =~ "«defp function_arity(:bar), do: :ok»"
      assert decorate(doc, second.detail_range) =~ "defp «function_arity(:bar)», do: :ok"

      assert third.name == "function_arity(:baz)"
      assert decorate(doc, third.range) =~ "«defp function_arity(:baz), do: :ok»"
      assert decorate(doc, third.detail_range) =~ "defp «function_arity(:baz)», do: :ok"
    end

    test "groups public and private functions separately" do
      {[module], _doc} =
        ~q[
        defmodule Module do
          def fun_one(:foo), do: :ok
          def fun_one(:bar), do: :ok

          defp fun_one(:foo, :bar), do: :ok
          defp fun_one(:bar, :baz), do: :ok
        end
        ]
        |> document_symbols()

      assert [first, second] = module.children
      assert first.name == "def fun_one/1"
      assert second.name == "defp fun_one/2"
    end

    test "line breaks are stripped" do
      {[module], _doc} =
        ~q[
        defmodule Module do
          def long_function(
               arg_1,
               arg_2,
               arg_3) do
          end
        end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert function.name == "def long_function( arg_1, arg_2, arg_3)"
    end

    test "line breaks are stripped for grouped functions" do
      {[module], _doc} =
        ~q[
        defmodule Module do
          def long_function(
               :foo,
               arg_2,
               arg_3) do
          end

          def long_function(
               :bar,
               arg_2,
               arg_3) do
          end
          def long_function(
               :baz,
               arg_2,
               arg_3) do
          end

        end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert function.name == "def long_function/3"

      assert [first, second, third] = function.children
      assert first.name == "long_function( :foo, arg_2, arg_3)"
      assert second.name == "long_function( :bar, arg_2, arg_3)"
      assert third.name == "long_function( :baz, arg_2, arg_3)"
    end

    test "struct definitions are found" do
      {[module], doc} =
        ~q{
        defmodule Module do
          defstruct [:name, :value]
        end
        }
        |> document_symbols()

      assert [struct] = module.children
      assert decorate(doc, struct.detail_range) =~ "  «defstruct [:name, :value]»"
      assert struct.name == "%Module{}"
      assert struct.type == :struct
    end

    test "struct references are skippedd" do
      assert {[], _doc} =
               ~q[%OtherModule{}]
               |> document_symbols()
    end

    test "variable definitions are skipped" do
      {[module], _doc} =
        ~q[
        defmodule Module do
          defp my_fn do
            my_var = 3
          end
        end
        ]
        |> document_symbols()

      assert [function] = module.children
      assert [] = function.children
    end

    test "variable references are skipped" do
      {[module], doc} =
        ~q[
        defmodule Module do
          defp my_fn do
            my_var = 3
            my_var
          end
        end
        ]
        |> document_symbols()

      [fun] = module.children
      assert decorate(doc, fun.detail_range) =~ "  defp «my_fn» do"
      assert fun.type == {:function, :private}
      assert fun.name == "defp my_fn"
      assert [] == fun.children
    end

    test "guards shown in the name" do
      {[module], doc} =
        ~q[
        defmodule Module do
          def my_fun(x) when x > 0 do
          end
        end
        ]
        |> document_symbols()

      [fun] = module.children
      assert decorate(doc, fun.detail_range) =~ "  def «my_fun(x) when x > 0» do"
      assert fun.type == {:function, :public}
      assert fun.name == "def my_fun(x) when x > 0"
      assert [] == fun.children
    end

    test "types show only their name" do
      {[module], doc} =
        ~q[
        @type something :: :ok
        ]
        |> in_a_module()
        |> document_symbols()

      assert module.type == :module

      [type] = module.children
      assert decorate(doc, type.detail_range) =~ "«@type something :: :ok»"
      assert type.name == "@type something"
      assert type.type == :type
    end

    test "specs are ignored" do
      {[module], _doc} =
        ~q[
        @spec my_fun(integer()) :: :ok
        ]
        |> in_a_module()
        |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "docs are ignored" do
      assert {[module], _doc} =
               ~q[
                @doc """
                 Hello
                """
               ]
               |> in_a_module()
               |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "moduledocs are ignored" do
      assert {[module], _doc} =
               ~q[
                @moduledoc """
                 Hello
                """
               ]
               |> in_a_module()
               |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "derives are ignored" do
      assert {[module], _doc} =
               ~q[
                 @derive {Something, other}
               ]
               |> in_a_module()
               |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "impl declarations are ignored" do
      assert {[module], _doc} =
               ~q[
                @impl GenServer
               ]
               |> in_a_module()
               |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "tags ignored" do
      assert {[module], _doc} =
               ~q[
                @tag :skip
               ]
               |> in_a_module()
               |> document_symbols()

      assert module.type == :module
      assert module.children == []
    end

    test "returns symbols for invalid code with partial AST" do
      {symbols, doc} =
        ~q[
        defmodule MyModule do
          def valid_function do
            :ok
          end

          def broken_function(arg do
            :error
          end
        end
        ]
        |> document_symbols()

      assert [%Document{} = module] = symbols
      assert module.name == "MyModule"
      assert module.type == :module
      assert module.subject == MyModule
      assert decorate(doc, module.detail_range) =~ "defmodule «MyModule» do"

      assert [%Document{} = function] = module.children
      assert function.name == "def valid_function"
      assert function.type == {:function, :public}
      assert function.subject == "MyModule.valid_function/0"
      assert decorate(doc, function.detail_range) =~ "def «valid_function» do"
      assert function.children == []
    end

    test "preserves bodyless default headers in a partial AST" do
      {[module], doc} =
        ~q[
        defmodule MyModule do
          def valid_function(arg \\ :default)

          def broken_function(arg do
            :error
          end
        end
        ]
        |> document_symbols()

      assert [zero_arity, one_arity] = module.children
      assert zero_arity.subject == "MyModule.valid_function/0"
      assert one_arity.subject == "MyModule.valid_function/1"
      assert zero_arity.type == {:function, :public}
      assert one_arity.type == {:function, :public}
      assert extract(doc, one_arity.detail_range) == ~S"valid_function(arg \\ :default)"
    end

    test "returns symbols for invalid code with module attributes" do
      {symbols, doc} =
        ~q[
        defmodule PartialModule do
          @my_attr 42

          def complete_fn, do: :ok

          def incomplete(
        end
        ]
        |> document_symbols()

      assert length(symbols) == 3

      [module, attr, function] =
        Enum.sort_by(symbols, fn s -> {s.range.start.line, s.range.start.character} end)

      assert module.name == "PartialModule"
      assert module.type == :module
      assert module.subject == PartialModule
      assert decorate(doc, module.detail_range) =~ "defmodule «PartialModule» do"
      assert module.children == []

      assert attr.name == "@my_attr"
      assert attr.type == :module_attribute
      assert attr.subject == "@my_attr"
      assert decorate(doc, attr.detail_range) =~ "«@my_attr 42»"

      assert function.name == "def complete_fn"
      assert function.type == {:function, :public}
      assert function.subject == "PartialModule.complete_fn/0"
      assert decorate(doc, function.detail_range) =~ "def «complete_fn», do: :ok"
    end

    test "returns symbols for invalid code with missing end" do
      {symbols, doc} =
        ~q[
        defmodule ModuleWithMissingEnd do
          @config :value

          def first_fn do
            :first
          end

          def second_fn do
            :second

        end
        ]
        |> document_symbols()

      assert [%Document{} = module] = symbols
      assert module.name == "ModuleWithMissingEnd"
      assert module.type == :module
      assert decorate(doc, module.detail_range) =~ "defmodule «ModuleWithMissingEnd» do"
      assert length(module.children) == 3

      children_by_name = Map.new(module.children, &{&1.name, &1})

      assert %Document{} = attr = children_by_name["@config"]
      assert attr.type == :module_attribute
      assert decorate(doc, attr.detail_range) =~ "«@config :value»"

      assert %Document{} = first = children_by_name["def first_fn"]
      assert first.type == {:function, :public}
      assert first.subject == "ModuleWithMissingEnd.first_fn/0"
      assert decorate(doc, first.detail_range) =~ "def «first_fn» do"

      assert %Document{} = second = children_by_name["def second_fn"]
      assert second.type == {:function, :public}
      assert second.subject == "ModuleWithMissingEnd.second_fn/0"
      assert decorate(doc, second.detail_range) =~ "def «second_fn» do"
    end

    test "returns empty symbols for completely unparseable code" do
      {symbols, _doc} =
        "}{]["
        |> document_symbols()

      assert is_list(symbols)
      assert symbols == []
    end

    test "returns some symbols for syntactically incorrect code with incomplete grouped aliases" do
      {symbols, _doc} =
        ~q[
        defmodule MyModule do
          alias Foo.{Bar
        end
        ]
        |> document_symbols()

      assert [%Document{} = module] = symbols
      assert module.name == "MyModule"
      assert module.type == :module

      {symbols, _doc} =
        ~q[
        defmodule MyModule do
          alias Foo.{Bar,
        end
        ]
        |> document_symbols()

      assert [%Document{} = module] = symbols
      assert module.name == "MyModule"
      assert module.type == :module
    end
  end

  describe "workspace symbols" do
    test "converts a module entry" do
      {[module], doc, uri} =
        ~q[
          defmodule Parent.Child do
          end
        ]
        |> workspace_symbols()

      assert module.type == :module
      assert module.name == "Parent.Child"
      assert module.link.uri == uri
      refute module.container_name

      assert decorate(doc, module.link.range) =~ "«defmodule Parent.Child do\nend»"
      assert decorate(doc, module.link.detail_range) =~ "defmodule «Parent.Child» do"
    end

    test "converts a function entry with zero args" do
      {[_module, public_function, private_function], doc, uri} =
        ~q[
          defmodule Parent.Child do
            def my_fn do
            end

            defp private_fun(a, b) do
            end
        end
        ]
        |> workspace_symbols()

      assert public_function.type == {:function, :public}
      assert String.ends_with?(public_function.name, ".my_fn/0")
      assert public_function.link.uri == uri
      refute public_function.container_name

      assert decorate(doc, public_function.link.range) =~ "  «def my_fn do\n  end»"
      assert decorate(doc, public_function.link.detail_range) =~ "  def «my_fn» do"

      assert private_function.type == {:function, :private}
      assert private_function.name == "Parent.Child.private_fun/2"
      assert private_function.link.uri == uri
      refute private_function.container_name

      assert decorate(doc, private_function.link.range) =~ "  «defp private_fun(a, b) do\n  end»"
      assert decorate(doc, private_function.link.detail_range) =~ "  defp «private_fun(a, b)» do"
    end

    test "converts protocol implementations" do
      {symbols, _doc, _uri} =
        ~q[
        defimpl SomeProtocol, for: Atom do
          def do_stuff(atom, opts) do
          end
        end
        ]
        |> workspace_symbols()

      [proto_impl, defined_module, protocol_module, proto_target, function] = symbols

      assert proto_impl.type == {:protocol, :implementation}
      assert proto_impl.name == "SomeProtocol"

      assert defined_module.type == :module
      assert defined_module.name == "SomeProtocol.Atom"

      assert protocol_module.type == :module
      assert protocol_module.name == "SomeProtocol"

      assert proto_target.type == :module
      assert proto_target.name == "Atom"

      assert function.type == {:function, :public}
      assert function.name == "SomeProtocol.Atom.do_stuff/2"
    end

    test "converts bodyless protocol declarations to public function symbols" do
      {[protocol, function], _doc, _uri} =
        ~q[
          defprotocol MyProto do
             def do_stuff(something, other)
          end
        ]
        |> workspace_symbols()

      assert protocol.type == {:protocol, :definition}
      assert protocol.name == "MyProto"

      assert function.type == {:function, :public}
      assert function.name == "MyProto.do_stuff/2"
    end
  end
end
