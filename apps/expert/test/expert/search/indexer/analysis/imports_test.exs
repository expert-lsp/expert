defmodule Expert.Search.Indexer.Analysis.ImportsTest do
  use ExUnit.Case, async: true

  import Forge.Test.CursorSupport

  alias Expert.Search.Indexer.Analysis.Imports
  alias Forge.Ast

  defmodule EnumUse do
    defmacro __using__(_opts) do
      quote do
        import Enum, only: [map: 2]
      end
    end
  end

  test "returns imports from a completed use" do
    imports =
      imports_at_cursor("""
      defmodule Example do
        use #{inspect(EnumUse)}
        |
      end
      """)

    assert {Enum, :map, 2} in imports
  end

  test "does not return imports before a use" do
    imports =
      imports_at_cursor("""
      defmodule Example do
        |
        use #{inspect(EnumUse)}
      end
      """)

    refute {Enum, :map, 2} in imports
  end

  test "does not return imports from a sibling function" do
    imports =
      imports_at_cursor("""
      defmodule Example do
        def foo do
          use #{inspect(EnumUse)}
        end

        def bar do
          |
        end
      end
      """)

    refute {Enum, :map, 2} in imports
  end

  defp imports_at_cursor(source) do
    {position, document} = pop_cursor(source, as: :document)

    document
    |> Ast.analyze(expand_uses: true)
    |> Imports.at(position)
  end
end
