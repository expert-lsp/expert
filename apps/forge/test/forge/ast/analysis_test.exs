defmodule Forge.Ast.AnalysisTest do
  use ExUnit.Case, async: true

  import Forge.Test.CursorSupport

  alias Forge.Ast.Analysis

  defmodule Setup do
    defmacro helpers do
      quote do
        import Enum, only: [map: 2]

        alias Forge.Ast.AnalysisTest.Target.Layouts
      end
    end
  end

  defmodule EnumUse do
    defmacro __using__(_opts) do
      quote do
        import Enum, only: [map: 2]
      end
    end
  end

  describe "cursor_env/2" do
    test "reads the imports and aliases that a macro adds" do
      env =
        cursor_env("""
        defmodule Example do
          require #{inspect(Setup)}
          #{inspect(Setup)}.helpers()
          map([], & &1)|
        end
        """)

      assert {Enum, :map, 2} in env.imports
      assert env.aliases[[:Layouts]] == Forge.Ast.AnalysisTest.Target.Layouts
    end

    test "reads the imports of use" do
      env =
        cursor_env("""
        defmodule Example do
          use #{inspect(EnumUse)}
          |
        end
        """)

      assert {Enum, :map, 2} in env.imports
    end

    test "applies an import that follows a macro" do
      env =
        cursor_env("""
        defmodule Example do
          use #{inspect(EnumUse)}
          import Enum, only: [filter: 2]
          |
        end
        """)

      assert {Enum, :filter, 2} in env.imports
      refute {Enum, :map, 2} in env.imports
    end

    test "reads only the code before the cursor" do
      env =
        cursor_env("""
        defmodule Example do
          |
          use #{inspect(EnumUse)}
        end
        """)

      refute {Enum, :map, 2} in env.imports
    end

    test "reads only the enclosing function" do
      env =
        cursor_env("""
        defmodule Example do
          def foo do
            use #{inspect(EnumUse)}
          end

          def bar do
            |
          end
        end
        """)

      refute {Enum, :map, 2} in env.imports
    end

    test "reads a document with syntax errors" do
      env =
        cursor_env("""
        defmodule Example do
          use #{inspect(EnumUse)}
          map([], |
        end
        """)

      assert {Enum, :map, 2} in env.imports
    end
  end

  defp cursor_env(source) do
    {position, document} = pop_cursor(source, as: :document)
    Analysis.cursor_env(document, position)
  end
end
