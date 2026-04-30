defmodule ReferencesTestSupport.B do
  def foo, do: 1
end

defmodule ReferencesTestSupport.A do
  defmacro __using__(ast) do
    quote do
      import ReferencesTestSupport.B

      unquote(ast)
    end
  end
end

defmodule Engine.CodeIntelligence.ReferencesTest do
  use ExUnit.Case, async: false

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  alias Elixir.Features
  alias Engine.CodeIntelligence.References
  alias Engine.Search
  alias Engine.Search.Store.Backends
  alias Forge.Document
  alias Forge.Document.Location

  setup do
    project = project()

    Backends.Ets.destroy_all(project)
    Engine.set_project(project)

    start_supervised!(Engine.ApplicationCache)
    start_supervised!(Document.Store)
    start_supervised!(Engine.Dispatch)
    start_supervised!(Backends.Ets)

    start_supervised!(
      {Search.Store, [project, fn _ -> {:ok, []} end, fn _, _ -> {:ok, [], []} end, Backends.Ets]}
    )

    Search.Store.enable()
    assert_eventually Search.Store.loaded?(), 1500

    on_exit(fn ->
      Backends.Ets.destroy_all(project)
    end)

    {:ok, project: project}
  end

  defp module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp project_module(project, content) do
    uri = module_uri(project)

    with :ok <- Document.Store.open(uri, content, 1) do
      Document.Store.fetch(uri)
    end
  end

  describe "function references" do
    test "are found inside public functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          def func(x), do: Enum.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "def func(x), do: «Enum.map(x, & &1 + 1)»"
    end

    test "are found inside private functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          defp func(x), do: Enum.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «Enum.map(x, & &1 + 1)»"
    end

    test "are found in aliased functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          alias Enum, as: E
          defp func(x), do: E.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «E.map(x, & &1 + 1)»"
    end

    test "are found in imported functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          import Enum, only: [map: 2]
          defp func(x), do: map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «map(x, & &1 + 1)»"
    end

    @tag skip: !Features.macro_env_functions_avaialable?()
    test "are found via imports injected by a use macro", %{project: project} do
      referenced = ~q/
        defmodule ReferencesTestSupport.B do
          def foo|(), do: 1
        end
      /

      code = ~q/
        defmodule MyProject do
          use ReferencesTestSupport.A

          def test() do
            foo()
          end
        end
      /

      assert [%Location{} = location] = references(project, referenced, code)
      assert decorate(code, location.range) =~ "«foo()»"
    end

    test "are found in local functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          def do_map(a, b), do: Enum.map(a, b)

          def func(x), do: do_map(x, & &1 + 1)

        end
      /
      assert [%Location{} = location] = references(project, "Functions.do_map|(a, b)", code)
      assert decorate(code, location.range) =~ "def func(x), do: «do_map(x, & &1 + 1)»"
    end

    test "are found in function definitions with optional arguments", %{project: project} do
      referenced = ~q/
      defmodule Functions do
        def do_map|(a, b, c \\ 3), do: {a, b, c}
        def func(x), do: do_map(x, 3, 5)
        def func2(x), do: do_map(x, 3)
      end
      /

      {_, code} = pop_cursor(referenced)

      references = references(project, referenced, code)
      assert [first, second] = Enum.sort_by(references, & &1.range.start.line)
      assert decorate(code, first.range) =~ "  def func(x), do: «do_map(x, 3, 5)»"
      assert decorate(code, second.range) =~ "  def func2(x), do: «do_map(x, 3)»"
    end
  end

  describe "module references" do
    # Note: These tests aren't exhaustive, as that is covered by Search.StoreTest.
    test "are found in an alias", %{project: project} do
      code = ~q[
        defmodule ReferencesInAlias do
          alias ReferencedModule
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[alias «ReferencedModule»]
    end

    test "are found in a module attribute", %{project: project} do
      code = ~q[
        defmodule ReferenceInAttribute do
          @attr ReferencedModule
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[@attr «ReferencedModule»]
    end

    test "are found in a variable", %{project: project} do
      code = ~q[
        some_module = ReferencedModule
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[some_module = «ReferencedModule»]
    end

    test "are found in a function's parameters", %{project: project} do
      code = ~q[
        def some_fn(ReferencedModule) do
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[def some_fn(«ReferencedModule») do]
    end

    test "includes struct definitions", %{project: project} do
      code = ~q[
        %ReferencedModule{} = something_else
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[%«ReferencedModule»{} = something_else]
    end

    test "includes definitions if the parameter is true", %{project: project} do
      code = ~q[
        defmodule DefinedModule do
        end

        defmodule OtherModule do
          @attr DefinedModule
        end
      ]

      assert [location_1, location_2] = references(project, "DefinedModule|", code, true)
      assert decorate(code, location_1.range) =~ ~s[defmodule «DefinedModule» do]
      assert decorate(code, location_2.range) =~ ~s[@attr «DefinedModule»]
    end
  end

  describe "struct references" do
    test "includes their definition if the parameter is true", %{project: project} do
      code = ~q(
      defmodule Struct do
        defstruct [:field]
      end
      )

      assert [location] = references(project, "%Struct|{}", code, true)
      assert decorate(code, location.range) =~ "«defstruct [:field]»"
    end

    test "includes references if defstruct is selected", %{project: project} do
      code = ~q[
        defmodule UsesStruct do
          def something(%Struct{}) do
          end
        end
      ]

      selector = ~q(
      defmodule Struct do
        defstruc|t [:name, :value]
      end
      )
      assert [location] = references(project, selector, code)
      assert decorate(code, location.range) =~ "def something(«%Struct{}») do"
    end

    test "excludes their definition", %{project: project} do
      code = ~q(
      defmodule Struct do
        defstruct [:field]
      end
      )

      assert [] = references(project, "%Struct|{}", code)
    end
  end

  describe "module attribute references" do
    test "are found in a module", %{project: project} do
      code = ~q[
      defmodule Refs do
        @attr 3

        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end

      ]

      assert [reference] = references(project, query, code)
      assert decorate(code, reference.range) =~ "  def fun(«@attr»), do: true"
    end

    test "includes definitions if the parameter is true", %{project: project} do
      code = ~q[
      defmodule Refs do
        @attr 3

        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end

      ]

      assert [definition, reference] = references(project, query, code, true)
      assert decorate(code, definition.range) =~ "«@attr 3»"
      assert decorate(code, reference.range) =~ "  def fun(«@attr»), do: true"
    end
  end

  describe "variable references" do
    test "are found in a function body", %{project: project} do
      query = ~S[
        def my_fun do
          first| = 4
          y = first * 2
          z = y * 3 + first
        end
      ]

      {_, code} = pop_cursor(query)

      assert [ref_1, ref_2] = references(project, query, code)

      assert decorate(code, ref_1.range) =~ "  y = «first» * 2"
      assert decorate(code, ref_2.range) =~ "  z = y * 3 + «first»"
    end

    test "can include definitions", %{project: project} do
      query = ~S[
        def my_fun do
          first = 4
          y = first| * 2
          z = y * 3 + first
        end
      ]

      {_, code} = pop_cursor(query)

      assert [definition, _ref_1, _ref_2] = references(project, query, code, true)
      assert decorate(code, definition.range) =~ "  «first» = 4"
    end
  end

  describe "unsupported entities" do
    test "returns an empty list for plain atoms", %{project: project} do
      query = ~S[
        defmodule MyModule do
          def my_fun do
            :stub_create_consent|
          end
        end
      ]

      {_, code} = pop_cursor(query)

      assert [] == references(project, query, code)
    end
  end

  defp references(project, referenced, code, include_definitions? \\ false) do
    with {position, referenced} <- pop_cursor(referenced, as: :document),
         {:ok, document} <- project_module(project, code),
         {:ok, entries} <- Search.Indexer.Source.index(document.path, code),
         :ok <- Search.Store.replace(entries) do
      referenced
      |> Forge.Ast.analyze()
      |> References.references(position, include_definitions?)
    end
  end
end
