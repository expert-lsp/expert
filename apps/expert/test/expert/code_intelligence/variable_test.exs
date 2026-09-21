defmodule Expert.CodeIntelligence.VariableTest do
  use ExUnit.Case

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.RangeSupport

  alias Expert.CodeIntelligence.Variable
  alias Forge.Ast

  def find_definition(code) do
    {position, document} = pop_cursor(code, as: :document)
    analysis = Ast.analyze(document)
    {:ok, {:local_or_var, var_name}} = Ast.cursor_context(analysis, position)

    case Variable.definition(analysis, position, List.to_atom(var_name)) do
      {:ok, entry} -> {:ok, entry.range, document}
      error -> error
    end
  end

  def find_references(code, include_definition? \\ false) do
    {position, document} = pop_cursor(code, as: :document)
    analysis = Ast.analyze(document)
    {:ok, {:local_or_var, var_name}} = Ast.cursor_context(analysis, position)

    ranges =
      analysis
      |> Variable.references(position, List.to_atom(var_name), include_definition?)
      |> Enum.map(& &1.range)

    {:ok, ranges, document}
  end

  describe "definitions in a single scope" do
    test "are returned if it is selected" do
      {:ok, range, doc} =
        ~q[
          def foo(param|) do
            param
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "def foo(«param») do"
    end

    test "are found in a parameter" do
      {:ok, range, doc} =
        ~q[
          def foo(param) do
            param|
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "def foo(«param») do"
    end

    test "are found in a parameter list" do
      {:ok, range, doc} =
        ~q[
          def foo(other_param, param) do
            param|
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "def foo(other_param, «param») do"
    end

    test "are found when shadowed" do
      {:ok, range, doc} =
        ~q[
          def foo(param) do
            param = param + 1
            param|
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "«param» = param + 1"
    end

    test "are found when shadowing a parameter" do
      {:ok, range, doc} =
        ~q[
          def foo(param) do
            param = param| + 1
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "def foo(«param») do"
    end

    test "when there are multiple definitions on one line" do
      {:ok, range, doc} =
        ~q[
            param = 3
            foo = param = param + 1
            param|
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "= «param» = param + 1"
    end

    test "when the definition is in a map key" do
      {:ok, range, doc} =
        ~q[
          %{key: value} = map
          value|
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "%{key: «value»} = map"
    end
  end

  describe "definitions across scopes" do
    test "works in an if in a function" do
      {:ok, range, doc} =
        ~q[
          def my_fun do
            foo = 3
            if something do
              foo|
            end
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "«foo» = 3"
    end

    test "works for variables defined in a module" do
      {:ok, range, doc} =
        ~q[
          defmodule Parent do
            x = 3
            def fun do
              unquote(x|)
            end
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "«x» = 3"
    end

    test "works for variables defined outside module" do
      {:ok, range, doc} =
        ~q[
          x = 3
          defmodule Parent do
            def fun do
              unquote(x|)
            end
          end
        ]
        |> find_definition()

      assert decorate(doc, range) =~ "«x» = 3"
    end
  end

  describe "references" do
    test "in a function parameter" do
      {:ok, [range], doc} =
        ~q[
          def something(param|) do
            param
          end
        ]
        |> find_references()

      assert decorate(doc, range) =~ "«param»"
    end

    test "can include definitions" do
      {:ok, [definition, reference], doc} =
        ~q[
          def something(param|) do
            param
          end
        ]
        |> find_references(true)

      assert decorate(doc, definition) =~ "def something(«param») do"
      assert decorate(doc, reference) =~ "  «param»"
    end

    test "can be found via a usage" do
      {:ok, [first, second, third], doc} =
        ~q[
          def something(param) do
           y = param + 3
           z = param + 4
           param| + y + z
          end
        ]
        |> find_references()

      assert decorate(doc, first) =~ " y = «param» + 3"
      assert decorate(doc, second) =~ " z = «param» + 4"
      assert decorate(doc, third) =~ " «param» + y + z"
    end

    test "are found in a function body" do
      {:ok, [first, second, third, fourth, fifth], doc} =
        ~q[
          def something(param|) do
            x = param + param + 3
            y = param + x
            z = 10 + param
            x + y + z + param
          end
        ]
        |> find_references()

      assert decorate(doc, first) =~ "  x = «param» + param + 3"
      assert decorate(doc, second) =~ "  x = param + «param» + 3"
      assert decorate(doc, third) =~ "  y = «param» + x"
      assert decorate(doc, fourth) =~ "  z = 10 + «param»"
      assert decorate(doc, fifth) =~ " x + y + z + «param»"
    end

    test "are constrained to their definition function" do
      {:ok, [range], doc} =
        ~q[
          def something(param|) do
            param
          end

          def other_fn(param) do
            param + 1
          end
        ]
        |> find_references()

      assert decorate(doc, range) =~ "«param»"
    end

    test "are visible across blocks" do
      {:ok, [first, second], doc} =
        ~q[
          def something(param|) do
            if something() do
              param + 1
            else
              param + 2
            end
          end
        ]
        |> find_references()

      assert decorate(doc, first) =~ "  «param» + 1"
      assert decorate(doc, second) =~ "  «param» + 2"
    end

    test "dont leak out of blocks" do
      {:ok, [range], doc} =
        ~q[
          def something(param) do

            if something() do
              param| = 3
              param + 1
            end
            param + 1
          end
        ]
        |> find_references()

      assert decorate(doc, range) =~ "«param»"
    end

    test "are found in the head of a case statement" do
      {:ok, [range], doc} =
        ~q[
          def something(param|) do
            case param do
             _ -> :ok
            end
          end
        ]
        |> find_references()

      assert decorate(doc, range) =~ "  case «param» do"
    end

    test "are constrained to a single arm of a case statement" do
      {:ok, [guard_range, usage_range], doc} =
        ~q[
          def something(param) do
            case param do
             param| when is_number(param) -> param + 1
             param -> 0
            end
          end
        ]
        |> find_references()

      assert decorate(doc, guard_range) =~ "  param when is_number(«param») -> param + 1"
      assert decorate(doc, usage_range) =~ "  param when is_number(param) -> «param» + 1"
    end

    test "are found in a module body" do
      {:ok, [range], doc} =
        ~q[
        defmodule Outer do
          something| = 3
          def foo(unquote(something)) do
          end
        end
        ]
        |> find_references()

      assert decorate(doc, range) =~ "def foo(unquote(«something»)) do"
    end

    test "are found in anonymous function parameters" do
      {:ok, [first, second], doc} =
        ~q[
        def outer do
          fn param| ->
            y = param + 1
            x = param + 2
            x + y
          end
        end
        ]
        |> find_references()

      assert decorate(doc, first) =~ "y = «param» + 1"
      assert decorate(doc, second) =~ "x = «param» + 2"
    end

    test "are found in a pin operator" do
      {:ok, [ref], doc} =
        ~q[
        def outer(param|) do
          fn ^param ->
            nil
          end
        end
        ]
        |> find_references()

      assert decorate(doc, ref) =~ "fn ^«param» ->"
    end

    test "are found inside of string interpolation" do
      {:ok, [ref], doc} =
        ~S[
          name| = "Stinky"
          "#{name} Stinkman"
        ]
        |> find_references()

      assert decorate(doc, ref) =~ "\#{«name»} Stinkman"
    end

    # Note: This test needs to pass before we can implement renaming variables reliably
    @tag :skip
    test "works for variables defined outside of an if while being shadowed" do
      {:ok, [first, second], doc} =
        ~q{
          entries| = [1, 2, 3]
          entries =
            if something() do
              [4 | entries]
            else
              entries
            end
        }
        |> find_references()

      assert decorate(doc, first) =~ "[4 | «entries»]"
      assert decorate(doc, second) =~ "«entries»"
    end

    test "finds variables defined in anonymous function arms" do
      {:ok, [first, second], doc} =
        ~q"
          shadowed? = false
          fn
          {:foo, entries|} ->
            if shadowed? do
              [1, entries]
            else
              entries
            end
          {:bar, entries} ->
            entries
          end
        "
        |> find_references()

      assert decorate(doc, first) =~ "[1, «entries»]"
      assert decorate(doc, second) =~ "«entries»"
    end
  end

  describe "reference shadowing" do
    test "on a single line" do
      {:ok, [], _doc} =
        ~q[
          def something(param) do
            other = other = other| = param
          end
      ]
        |> find_references()
    end

    test "in a function body" do
      {:ok, [], _doc} =
        ~q[
          def something(param|) do
           param = 3
           param
          end
      ]
        |> find_references()
    end

    test "in anonymous function arguments" do
      {:ok, [], _doc} =
        ~q[
          def something(param|) do
           fn param ->
             param + 1
           end
           :ok
          end
        ]
        |> find_references()
    end

    test "inside of a block" do
      {:ok, [range], doc} =
        ~q[
          def something do
           shadow| = 4
           if true do
             shadow = shadow + 1
             shadow
           end
          end
        ]
        |> find_references()

      assert decorate(doc, range) == "   shadow = «shadow» + 1"
    end

    test "exiting a block" do
      {:ok, [range], doc} =
        ~q[
          def something do
           shadow| = 4
           if true do
             shadow = :ok
             shadow
           end
           shadow + 1
          end
        ]
        |> find_references()

      assert decorate(doc, range) == " «shadow» + 1"
    end

    test "exiting nested blocks" do
      {:ok, [range], doc} =
        ~q[
          def something(param| = arg) do
            case arg do
              param when is_number(n) ->
                param + 4
            end
            param + 5
          end
        ]
        |> find_references()

      assert decorate(doc, range) == "  «param» + 5"
    end
  end
end
