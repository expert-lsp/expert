defmodule Engine.Search.Indexer.MetadataTest do
  use ExUnit.Case

  import Forge.Test.CodeSigil
  import Forge.Test.RangeSupport

  alias Engine.Search.Indexer.Metadata
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  describe "blocks in modules" do
    test "finds the body rather than the target of a keyword-do implementation" do
      code = "defimpl Action, for: Atom, do: Target.run()"

      assert "defimpl Action, for: Atom, «do: Target.run()»" == decorate_location(code)
    end

    test "finds a block in an empty module" do
      code = ~q[
        defmodule MyModule do
        end
      ]t

      assert "defmodule MyModule «do\n»end" == decorate_location(code)
    end

    test "finds a block in a module with an attribute" do
      code = ~q[
        defmodule WithAttribute do
          @foo 32
        end
      ]t

      assert "defmodule WithAttribute «do\n  @foo 32\n»end" = decorate_location(code)
    end

    test "finds a block in a module with functions" do
      code = ~q[
        defmodule WithFunctions do
          def fun do
          end
        end
      ]t

      expected = ~q[
        defmodule WithFunctions «do
          def fun do
          end
        »end
      ]t
      assert expected == decorate_location(code)
    end
  end

  describe "blocks in functions" do
    test "are found in a public function with do/end and no body" do
      code = ~q[
      def my_fn do
      end
      ]
      assert "def my_fn «do\nend»" = decorate_location(code)
    end

    test "are found in a private function with do/end and no body" do
      code = ~q[
      defp my_fn do
      end
      ]
      assert "defp my_fn «do\nend»" = decorate_location(code)
    end

    test "are found in a public function with do/end and  abody" do
      code = ~q[
      def my_fn do
        x = 4
        x * 6
      end
      ]t

      expected = ~q[
      def my_fn «do
        x = 4
        x * 6
      »end
      ]t

      assert expected == decorate_location(code)
    end

    test "are found in a private function with do/end and  abody" do
      code = ~q[
      defp my_fn do
        x = 4
        x * 6
      end
      ]t

      expected = ~q[
      defp my_fn «do
        x = 4
        x * 6
      »end
      ]t

      assert expected == decorate_location(code)
    end

    test "are found in single line terse public function" do
      code = ~q[
        def my_fn(arg), do: arg * 10
      ]t

      assert "def my_fn(arg), «do: arg * 10»" = decorate_location(code)
    end

    test "are found in single line terse private function" do
      code = ~q[
        defp my_fn(arg), do: arg * 10
      ]t

      assert "defp my_fn(arg), «do: arg * 10»" = decorate_location(code)
    end

    test "are found in single line terse public macro" do
      code = ~q[
        defmacro my_fn(arg), do: arg * 10
      ]t

      assert "defmacro my_fn(arg), «do: arg * 10»" = decorate_location(code)
    end

    test "are found in single line terse private macro" do
      code = ~q[
        defmacrop my_fn(arg), do: arg * 10
      ]t

      assert "defmacrop my_fn(arg), «do: arg * 10»" = decorate_location(code)
    end

    test "are found in multiple line terse public function" do
      code = ~q[
      def my_fun(arg),
        do: arg + 1
      ]

      assert "  «do: arg + 1»" == decorate_location(code)
    end

    test "are found in multiple line terse private function" do
      code = ~q[
      defp my_fun(arg),
        do: arg + 1
      ]

      assert "  «do: arg + 1»" == decorate_location(code)
    end

    test "are found in anonymous functions with no body" do
      code = "fn -> :ok end"
      assert "«fn -> :ok end»" == decorate_location(code)
    end

    test "are found in single line anonymous functions" do
      code = "fn arg -> arg + 1  end"
      assert "«fn arg -> arg + 1  end»" == decorate_location(code)
    end

    test "are found in multiple line anonymous functions" do
      code = ~q[
        fn a, b ->
          y = do_something_with(a)
          z = do_something_with(b)
          y + z
        end]

      expected = ~q[
        «fn a, b ->
          y = do_something_with(a)
          z = do_something_with(b)
          y + z
        end»
      ]t

      assert expected == decorate_location(code)
    end
  end

  defp decorate_location(code) do
    document = Document.new("file:///file.ex", code, 1)
    {:ok, ast, _} = Ast.from(document)

    case Metadata.location(ast) do
      {:block, _position, {start_line, start_char}, {end_line, end_char}} ->
        range =
          Range.new(
            Position.new(document, start_line, start_char),
            Position.new(document, end_line, end_char)
          )

        decorate(code, range)
    end
  end
end
