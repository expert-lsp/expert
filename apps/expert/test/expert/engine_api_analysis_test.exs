defmodule Expert.EngineApiAnalysisTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Ast.Analysis

  defmodule EnumUse do
    defmacro __using__(_opts) do
      quote do
        import Enum, only: [map: 2]
      end
    end
  end

  setup do
    test_pid = self()

    patch(EngineApi, :call, fn _project, Analysis, :new, [parsed, document, opts] ->
      send(test_pid, {:project_analysis, parsed, opts})
      Analysis.new(parsed, document, opts)
    end)

    :ok
  end

  test "captures use imports through the existing analysis on the project node" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          use #{inspect(EnumUse)}
          map([], & &1)|
        end
        """,
        as: :document
      )

    original = Ast.analyze(document)
    parsed = Ast.from(original)
    expanded = EngineApi.reanalyze_to(project(), original, position)

    assert_receive {:project_analysis, ^parsed, [expand_uses: true]}

    assert [%{latest_expanded_use: %{imported_mfas: imports}} | _] =
             Analysis.scopes_at(expanded, position)

    assert {Enum, :map, 2} in imports
    assert expanded.document == document
    assert expanded.ast == original.ast
  end

  test "reuses analysis with captured imports" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          use #{inspect(EnumUse)}
          map([], & &1)|
        end
        """,
        as: :document
      )

    original = Ast.analyze(document, expand_uses: true)
    assert ^original = EngineApi.reanalyze_to(project(), original, position)
    refute_received {:project_analysis, _, _}
  end

  test "keeps explicit imports on the existing local path" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          import Enum
          map([], & &1)|
        end
        """,
        as: :document
      )

    original = Ast.analyze(document)
    assert ^original = EngineApi.reanalyze_to(project(), original, position)
    refute_received {:project_analysis, _, _}
  end

  test "does not expand a use after the cursor" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          map([], & &1)|
          use #{inspect(EnumUse)}
        end
        """,
        as: :document
      )

    original = Ast.analyze(document)
    assert ^original = EngineApi.reanalyze_to(project(), original, position)
    refute_received {:project_analysis, _, _}
  end

  test "does not expand a use from a sibling function" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          def foo do
            use #{inspect(EnumUse)}
            map([], & &1)
          end

          def bar do
            map([], & &1)|
          end
        end
        """,
        as: :document
      )

    original = Ast.analyze(document)
    assert ^original = EngineApi.reanalyze_to(project(), original, position)
    refute_received {:project_analysis, _, _}
  end

  test "captures use imports in a recovered cursor fragment" do
    {position, document} =
      pop_cursor(
        """
        defmodule Example do
          use #{inspect(EnumUse)}
          map([], |
        end
        """,
        as: :document
      )

    original = Ast.analyze(document)
    refute original.valid?
    expanded = EngineApi.reanalyze_to(project(), original, position)

    assert_receive {:project_analysis, {:ok, _, _}, [expand_uses: true]}

    assert [%{latest_expanded_use: %{imported_mfas: imports}} | _] =
             Analysis.scopes_at(expanded, position)

    assert {Enum, :map, 2} in imports
    assert expanded.valid?
    assert expanded.document == document
  end
end
