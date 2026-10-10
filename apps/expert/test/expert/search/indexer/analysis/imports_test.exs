defmodule Expert.Search.Indexer.Analysis.ImportsTest do
  use ExUnit.Case, async: true

  import Forge.Test.CursorSupport

  alias Expert.Search.Indexer.Analysis.Imports
  alias Expert.Test.EnumUse
  alias Forge.Ast
  alias Forge.Ast.Analysis

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

  test "returns the imports of a use only after it" do
    imports =
      imports_at_cursor("""
      defmodule Example do
        |
        use #{inspect(EnumUse)}
      end
      """)

    refute {Enum, :map, 2} in imports
  end

  test "returns only the imports of the enclosing function" do
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

  test "combines the environment at the cursor with the explicit imports of the scope" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          import Explicit
          |
        end
        """,
        as: :document
      )

    cursor_env = %{
      position: {position.line, position.character},
      imports: [{Enum, :map, 2}],
      aliases: %{}
    }

    analysis = %{Ast.analyze(document) | cursor_env: cursor_env}

    exports = fn
      Explicit -> {:ok, %{functions: [run: 0], macros: []}}
      _module -> :error
    end

    imports = Imports.at(analysis, position, exports)

    assert {Enum, :map, 2} in imports
    assert {Explicit, :run, 0} in imports
  end

  describe "module_for/4" do
    test "finds the module of a function that a macro imports" do
      {analysis, position} =
        analysis_with_cursor_env("""
        defmodule Example do
          use #{inspect(EnumUse)}
          |
        end
        """)

      assert {:ok, Enum} = Imports.module_for(analysis, position, :map, 2)
    end

    test "finds an imported function only after the macro that imports it" do
      {analysis, position} =
        analysis_with_cursor_env("""
        defmodule Example do
          |
          use #{inspect(EnumUse)}
        end
        """)

      assert :error = Imports.module_for(analysis, position, :map, 2)
    end
  end

  defp analysis_with_cursor_env(source) do
    {position, document} = pop_cursor(source, as: :document)
    cursor_env = Analysis.cursor_env(document, position)
    {%{Ast.analyze(document) | cursor_env: cursor_env}, position}
  end

  defp imports_at_cursor(source) do
    {position, document} = pop_cursor(source, as: :document)

    document
    |> Ast.analyze(expand_uses: true)
    |> Imports.at(position)
  end
end
