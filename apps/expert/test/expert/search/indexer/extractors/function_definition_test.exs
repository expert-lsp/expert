defmodule Expert.Search.Indexer.Extractors.FunctionDefinitionTest do
  use Expert.Test.ExtractorCase

  alias Forge.Search.Indexer.Entry

  def index(source) do
    do_index(source, fn %Entry{type: type} = entry ->
      match?({:function, _}, type) and entry.subtype == :definition
    end)
  end

  def index_functions(source) do
    do_index(source, fn %Entry{type: type} ->
      match?({:function, _}, type)
    end)
  end

  def index_macros(source) do
    do_index(source, fn %Entry{type: type} = entry ->
      match?({:macro, _}, type) and entry.subtype == :definition
    end)
  end

  describe "indexing public function definitions" do
    test "finds zero arity public functions (no parens)" do
      code =
        ~q[
          def zero_arity do
          end
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :public}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity" == extract(code, zero_arity.range)
      assert "def zero_arity do\nend" == extract(code, zero_arity.block_range)
    end

    test "finds zero arity one line public functions (no parens)" do
      code =
        ~q[
          def zero_arity, do: true
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :public}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity" == extract(code, zero_arity.range)
      assert "def zero_arity, do: true" == extract(code, zero_arity.block_range)
    end

    test "finds zero arity public functions (with parens)" do
      code =
        ~q[
          def zero_arity() do
          end
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :public}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity()" == extract(code, zero_arity.range)
      assert "def zero_arity() do\nend" == extract(code, zero_arity.block_range)
    end

    test "finds one arity public function" do
      code =
        ~q[
          def one_arity(a) do
            a + 1
          end
        ]
        |> in_a_module()

      {:ok, [one_arity], _} = index(code)

      assert one_arity.type == {:function, :public}
      assert one_arity.subtype == :definition
      assert one_arity.subject == "Parent.one_arity/1"
      assert "one_arity(a)" == extract(code, one_arity.range)
      assert "def one_arity(a) do\na + 1\nend" == extract(code, one_arity.block_range)
    end

    test "finds one arity public function with a guard" do
      code =
        ~q[
          def one_arity(a) when is_integer(a) do
            a + 1
          end
        ]
        |> in_a_module()

      {:ok, [one_arity], _} = index(code)

      assert one_arity.type == {:function, :public}
      assert one_arity.subtype == :definition
      assert one_arity.subject == "Parent.one_arity/1"
      assert "one_arity(a) when is_integer(a)" == extract(code, one_arity.range)

      assert "def one_arity(a) when is_integer(a) do\na + 1\nend" ==
               extract(code, one_arity.block_range)
    end

    test "finds multi arity public function" do
      code =
        ~q[
          def multi_arity(a, b, c, d) do
            {a, b, c, d}
          end
        ]
        |> in_a_module()

      {:ok, [multi_arity], _} = index(code)

      assert multi_arity.type == {:function, :public}
      assert multi_arity.subtype == :definition
      assert multi_arity.subject == "Parent.multi_arity/4"
      assert "multi_arity(a, b, c, d)" == extract(code, multi_arity.range)

      assert "def multi_arity(a, b, c, d) do\n{a, b, c, d}\nend" ==
               extract(code, multi_arity.block_range)
    end

    test "finds multi-line function definitions" do
      code =
        ~q[
          def multi_line(a,
          b,
          c,
          d) do
          end
        ]
        |> in_a_module()

      {:ok, [multi_line], _} = index(code)

      expected =
        """
        multi_line(a,
        b,
        c,
        d)
        """
        |> String.trim()

      assert expected == extract(code, multi_line.range)
    end

    test "finds functions defined in protocol implementations" do
      {:ok, [function], doc} =
        ~q[
          defimpl MyProtocol, for: Structs.Mystruct do
            def do_proto(a, b) do
              a + b
            end
          end
        ]
        |> index_functions()

      assert function.type == {:function, :public}
      assert function.subject == "MyProtocol.Structs.Mystruct.do_proto/2"
      assert "do_proto(a, b)" = extract(doc, function.range)
      assert decorate(doc, function.block_range) =~ "«def do_proto(a, b) do\n    a + b\n  end»"
    end

    test "finds functions defined with defdelegate" do
      {:ok, [function | _], doc} =
        ~q[
          defmodule MyModule do
            defdelegate map(enumerable, other), to: Enum
          end
        ]
        |> index_functions()

      assert function.type == {:function, :delegate}
      assert function.subject == "MyModule.map/2"
      assert "map(enumerable, other)" = extract(doc, function.range)
      assert decorate(doc, function.range) =~ "defdelegate «map(enumerable, other)», to: Enum"
    end

    test "finds functions defined with defdelegate with an aliased module" do
      {:ok, [function | _], doc} =
        ~q[
          defmodule MyModule do
            alias Parent.Child
            defdelegate map(enumerable, other), to: Child
          end
        ]
        |> index_functions()

      assert function.type == {:function, :delegate}
      assert function.subject == "MyModule.map/2"
      assert "map(enumerable, other)" = extract(doc, function.range)
      assert decorate(doc, function.range) =~ "defdelegate «map(enumerable, other)», to: Child"
    end

    test "skip quoted function defined with defdelegate" do
      assert {:ok, [], _doc} = ~q[
          quote do
            defdelegate unquote(symbol)(enumerable, other), to: Enum
          end
        ] |> index_functions()
    end

    test "finds functions defined with defdelegate and as" do
      {:ok, [function | _], doc} =
        ~q[
          defmodule MyModule do
            defdelegate collect(enumerable, other), to: Enum, as: :map
          end
        ]
        |> index_functions()

      assert function.type == {:function, :delegate}
      assert function.subject == "MyModule.collect/2"
      assert "collect(enumerable, other)" = extract(doc, function.range)

      assert decorate(doc, function.range) =~
               "  defdelegate «collect(enumerable, other)», to: Enum, as: :map"
    end

    test "indexes all callable arities for defdelegate with default arguments" do
      code =
        ~q[
          defmodule MyModule do
            defdelegate trim(value \\ " default "), to: String
          end
        ]

      {:ok, entries, _doc} = index(code)

      assert Enum.map(entries, & &1.subject) == [
               "MyModule.trim/0",
               "MyModule.trim/1"
             ]

      assert Enum.all?(entries, &(&1.type == {:function, :delegate}))
      assert Enum.all?(entries, &(&1.metadata.original_mfa == "String.trim/1"))
    end

    test "skips public functions defined in quote blocks" do
      code =
        ~q[
        def something(name) do
          quote do
            def unquote(name)() do
            end
          end
        end
        ]
        |> in_a_module()

      {:ok, [something], _} = index(code)
      assert "something(name)" = extract(code, something.range)
    end

    test "returns no references" do
      {:ok, [function_definition], doc} =
        ~q[
        def my_fn(a, b) do
        end
        ]
        |> in_a_module()
        |> index_functions()

      assert function_definition.type == {:function, :public}
      assert function_definition.subtype == :definition
      assert "my_fn(a, b)" = extract(doc, function_definition.range)
    end
  end

  describe "indexing private function definitions" do
    test "finds zero arity one-line private functions (no parens)" do
      code =
        ~q[
        defp zero_arity, do: true
      ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :private}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity" == extract(code, zero_arity.range)
      assert "defp zero_arity, do: true" == extract(code, zero_arity.block_range)
    end

    test "finds zero arity one-line private functions (with parens)" do
      code =
        ~q[
          defp zero_arity(), do: true
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :private}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity()" == extract(code, zero_arity.range)
      assert "defp zero_arity(), do: true" == extract(code, zero_arity.block_range)
    end

    test "finds zero arity private functions (no parens)" do
      code =
        ~q[
          defp zero_arity do
          end
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :private}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity" == extract(code, zero_arity.range)
      assert "defp zero_arity do\nend" == extract(code, zero_arity.block_range)
    end

    test "finds zero arity private functions (with parens)" do
      code =
        ~q[
          defp zero_arity() do
          end
        ]
        |> in_a_module()

      {:ok, [zero_arity], _} = index(code)

      assert zero_arity.type == {:function, :private}
      assert zero_arity.subtype == :definition
      assert zero_arity.subject == "Parent.zero_arity/0"
      assert "zero_arity()" == extract(code, zero_arity.range)
      assert "defp zero_arity() do\nend" == extract(code, zero_arity.block_range)
    end

    test "finds one arity one-line private functions" do
      code =
        ~q[
          defp one_arity(a), do: a + 1
        ]
        |> in_a_module()

      {:ok, [one_arity], _} = index(code)

      assert one_arity.type == {:function, :private}
      assert one_arity.subtype == :definition
      assert one_arity.subject == "Parent.one_arity/1"
      assert "one_arity(a)" == extract(code, one_arity.range)
      assert "defp one_arity(a), do: a + 1" == extract(code, one_arity.block_range)
    end

    test "finds one arity private functions" do
      code =
        ~q[
          defp one_arity(a) do
            a + 1
          end
        ]
        |> in_a_module()

      {:ok, [one_arity], _} = index(code)

      assert one_arity.type == {:function, :private}
      assert one_arity.subtype == :definition
      assert one_arity.subject == "Parent.one_arity/1"
      assert "one_arity(a)" == extract(code, one_arity.range)
      assert "defp one_arity(a) do\na + 1\nend" == extract(code, one_arity.block_range)
    end

    test "finds multi-arity one-line private functions" do
      code =
        ~q[
          defp multi_arity(a, b, c), do: {a, b, c}
        ]
        |> in_a_module()

      {:ok, [multi_arity], _} = index(code)

      assert multi_arity.type == {:function, :private}
      assert multi_arity.subtype == :definition
      assert multi_arity.subject == "Parent.multi_arity/3"
      assert "multi_arity(a, b, c)" == extract(code, multi_arity.range)
      assert "defp multi_arity(a, b, c), do: {a, b, c}" = extract(code, multi_arity.block_range)
    end

    test "finds multi arity private functions" do
      code =
        ~q[
          defp multi_arity(a, b, c, d) do
            {a, b, c, d}
          end
        ]
        |> in_a_module()

      {:ok, [multi_arity], _} = index(code)

      assert multi_arity.type == {:function, :private}
      assert multi_arity.subtype == :definition
      assert multi_arity.subject == "Parent.multi_arity/4"
      assert "multi_arity(a, b, c, d)" == extract(code, multi_arity.range)

      assert "defp multi_arity(a, b, c, d) do\n{a, b, c, d}\nend" ==
               extract(code, multi_arity.block_range)
    end

    test "skips private functions defined in quote blocks" do
      code =
        ~q[
          defp something(name) do
            quote do
              defp unquote(name)() do

              end
            end
          end
        ]
        |> in_a_module()

      {:ok, [something], _} = index(code)
      assert something.type == {:function, :private}
      assert "something(name)" = extract(code, something.range)
    end

    test "handles macro calls that define functions" do
      {:ok, [definition], doc} =
        ~q[
          quote do
            def rpc_call(pid, call = %Call{method: unquote(method_name)}),
                do: GenServer.unquote(genserver_method)(pid, call)
          end
        ]x
        |> in_a_module()
        |> index()

      assert definition.type == {:function, :public}

      assert decorate(doc, definition.range) =~
               "def «rpc_call(pid, call = %Call{method: unquote(method_name)})»"
    end

    test "returns no references" do
      {:ok, [function_definition], doc} =
        ~q[
        defp my_fn(a, b) do
        end
        ]
        |> in_a_module()
        |> index_functions()

      assert function_definition.type == {:function, :private}
      assert function_definition.subtype == :definition
      assert "my_fn(a, b)" = extract(doc, function_definition.range)
    end
  end

  describe "indexing functions with default arguments" do
    test "indexes all callable arities for a function with default arguments" do
      code = """
      defmodule Parent do
        def create(name \\\\ :default, public \\\\ false, opts \\\\ nil) do
          {name, public, opts}
        end
      end
      """

      {:ok, entries, _} = index(code)

      subjects = entries |> Enum.map(& &1.subject) |> Enum.sort()

      assert subjects == [
               "Parent.create/0",
               "Parent.create/1",
               "Parent.create/2",
               "Parent.create/3"
             ]
    end

    test "indexes all callable arities for a function with some default arguments" do
      code = """
      defmodule Parent do
        def create(name, public, opts \\\\ nil) do
          {name, public, opts}
        end
      end
      """

      {:ok, entries, _} = index(code)

      subjects = entries |> Enum.map(& &1.subject) |> Enum.sort()

      assert subjects == [
               "Parent.create/2",
               "Parent.create/3"
             ]
    end

    test "indexes all callable arities for a function with default arguments and guards" do
      code = """
      defmodule Parent do
        def create(name \\\\ :default, opts \\\\ []) when is_atom(name) do
          {name, opts}
        end
      end
      """

      {:ok, entries, _} = index(code)

      subjects = entries |> Enum.map(& &1.subject) |> Enum.sort()

      assert subjects == [
               "Parent.create/0",
               "Parent.create/1",
               "Parent.create/2"
             ]
    end
  end

  describe "indexing public macro definitions" do
    test "finds zero arity public macro (no parens)" do
      {:ok, [my_macro], doc} =
        ~q[
          defmacro my_macro do
          end
        ]
        |> in_a_module()
        |> index_macros()

      assert my_macro.type == {:macro, :public}
      assert my_macro.subtype == :definition
      assert my_macro.subject == "Parent.my_macro/0"
      assert "my_macro" = extract(doc, my_macro.range)
      assert decorate(doc, my_macro.block_range) =~ "«defmacro my_macro do\nend»"
    end

    test "finds one arity public macro" do
      {:ok, [my_macro], doc} =
        ~q[
          defmacro my_macro(ast) do
            ast
          end
        ]
        |> in_a_module()
        |> index_macros()

      assert my_macro.type == {:macro, :public}
      assert my_macro.subtype == :definition
      assert my_macro.subject == "Parent.my_macro/1"
      assert "my_macro(ast)" = extract(doc, my_macro.range)
      assert decorate(doc, my_macro.range) =~ "defmacro «my_macro(ast)» do"
    end
  end

  describe "indexing private macro definitions" do
    test "finds zero arity private macro (no parens)" do
      {:ok, [my_macro], doc} =
        ~q[
          defmacrop my_macro do
          end
        ]
        |> in_a_module()
        |> index_macros()

      assert my_macro.type == {:macro, :private}
      assert my_macro.subtype == :definition
      assert my_macro.subject == "Parent.my_macro/0"
      assert "my_macro" = extract(doc, my_macro.range)
      assert decorate(doc, my_macro.block_range) =~ "«defmacrop my_macro do\nend»"
    end

    test "finds one arity private macro" do
      {:ok, [my_macro], doc} =
        ~q[
          defmacrop my_macro(ast) do
            ast
          end
        ]
        |> in_a_module()
        |> index_macros()

      assert my_macro.type == {:macro, :private}
      assert my_macro.subtype == :definition
      assert my_macro.subject == "Parent.my_macro/1"
      assert "my_macro(ast)" = extract(doc, my_macro.range)
      assert decorate(doc, my_macro.range) =~ "defmacrop «my_macro(ast)» do"
    end
  end

  describe "recovers from invalid code" do
    test "with syntax errors" do
      assert {:ok, [], _doc} =
               ~q[
               defmodule Parent do
                 def my_fn(a, b
               end
               ]
               |> index()
    end
  end
end
