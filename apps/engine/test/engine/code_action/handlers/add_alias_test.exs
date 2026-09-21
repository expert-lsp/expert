defmodule Engine.CodeAction.Handlers.AddAliasTest do
  use Forge.Test.CodeMod.Case, enable_ast_conversion: false
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  alias Engine.CodeAction.Handlers.AddAlias
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Scope
  alias Forge.CodeUnit
  alias Forge.Document
  alias Forge.Document.Line
  alias Forge.Document.Range

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    :ok
  end

  def apply_code_mod(text, _ast, options) do
    range = options[:range]
    uri = "file:///file.ex"
    :ok = Document.Store.open(uri, text, 1)
    {:ok, document} = Document.Store.fetch(uri)

    edits =
      case AddAlias.actions(document, range, []) do
        [action] -> action.changes.edits
        _ -> []
      end

    {:ok, edits}
  end

  def add_alias(original_text, modules_to_return) do
    {position, stripped_text} = pop_cursor(original_text)
    patch_fuzzy_search(modules_to_return)
    range = Range.new(position, position)
    modify(stripped_text, range: range)
  end

  def patch_fuzzy_search(modules_to_return) do
    all_modules =
      Enum.map(modules_to_return, fn module ->
        {Atom.to_charlist(module), :code.which(module), :code.is_loaded(module)}
      end)

    patch(AddAlias, :all_modules, all_modules)
  end

  describe "in an existing module with no aliases" do
    test "aliases are added at the top of the module" do
      patch(Engine, :get_project, %Forge.Project{})

      {:ok, added} =
        ~q[
        defmodule MyModule do
          def my_fn do
            Line|
          end
        end
        ]
        |> add_alias([Line])

      expected = ~q[
      defmodule MyModule do
        alias Forge.Document.Line
        def my_fn do
          Line
        end
      end
      ]t
      assert added =~ expected
    end
  end

  describe "in an existing module" do
  end

  describe "in the root context" do
  end

  describe "adding an alias" do
    test "does nothing on an invalid document" do
      {:ok, added} = add_alias("%Engine.Search.", [Engine.Search])

      assert added == "%Engine.Search."
    end

    test "outside of a module with aliases" do
      {:ok, added} =
        ~q[
          alias ZZ.XX.YY
          Line|
        ]
        |> add_alias([Line])

      expected = ~q[
      alias Forge.Document.Line
      alias ZZ.XX.YY
      Line
      ]t

      assert added == expected
    end

    test "when a full module name is given" do
      {:ok, added} =
        ~q[
        Forge.Ast.Analysis.Scope|
        ]
        |> add_alias([Scope])

      expected = ~q[
        alias Forge.Ast.Analysis.Scope
        Scope
      ]t

      assert added == expected
    end

    test "when a full module name is given in a module function" do
      patch(Engine, :get_project, %Forge.Project{})

      {:ok, added} =
        ~q[
        defmodule MyModule do
          def my_fun do
            result = Forge.Ast.Analysis|
          end
        end
        ]
        |> add_alias([Analysis])

      expected = ~q[
        defmodule MyModule do
          alias Forge.Ast.Analysis
          def my_fun do
            result = Analysis
          end
        end
      ]t

      assert added =~ expected
    end

    test "outside of a module with no aliases" do
      {:ok, added} =
        ~q[Line|]
        |> add_alias([Line])

      expected = ~q[
       alias Forge.Document.Line
       Line
      ]t

      assert added == expected
    end

    test "in a module with no aliases" do
      patch(Engine, :get_project, %Forge.Project{})

      {:ok, added} =
        ~q[
        defmodule MyModule do
          def my_fun do
            Line|
          end
        end
        ]
        |> add_alias([Line])

      expected = ~q[
      defmodule MyModule do
        alias Forge.Document.Line
        def my_fun do
          Line
        end
      end
      ]t

      assert added =~ expected
    end

    test "outside of functions" do
      {:ok, added} =
        ~q[
        defmodule MyModule do
          alias Something.Else
          Line|
        end
        ]
        |> add_alias([Line])

      expected = ~q[
      defmodule MyModule do
        alias Forge.Document.Line
        alias Something.Else
        Line
      end
      ]

      assert expected =~ added
    end

    test "inside a function" do
      {:ok, added} =
        ~q[
        defmodule MyModule do
          alias Something.Else
          def my_fn do
            Line|
          end
        end
        ]
        |> add_alias([Line])

      expected = ~q[
      defmodule MyModule do
        alias Forge.Document.Line
        alias Something.Else
        def my_fn do
          Line
        end
      end
      ]
      assert expected =~ added
    end

    test "inside a nested module" do
      {:ok, added} =
        ~q[
          defmodule Parent do
            alias Top.Level
            defmodule Child do
              alias Some.Other
              Line|
            end
          end
        ]
        |> add_alias([Line])

      expected = ~q[
      defmodule Parent do
        alias Top.Level
        defmodule Child do
          alias Forge.Document.Line
          alias Some.Other
          Line
        end
      end
      ]t

      assert added =~ expected
    end

    test "aliases for struct references don't include non-struct modules" do
      {:ok, added} = add_alias("%Scope|{}", [Forge.Ast, Scope])

      expected = ~q[
      alias Forge.Ast.Analysis.Scope
      %Scope
      ]t

      assert added =~ expected
    end

    test "only modules with a similarly named function will be included in aliases" do
      {:ok, added} = add_alias("Document.fetch|", [Document, Engine])

      expected = ~q[
      alias Forge.Document
      Document.fetch
      ]t

      assert added =~ expected
    end

    test "protocols are excluded" do
      {:ok, added} = add_alias("Co|", [Collectable, CodeUnit])
      expected = ~q[
      alias Forge.CodeUnit
      Co
      ]t

      assert added =~ expected
    end

    test "protocol implementations are excluded" do
      {:ok, added} = add_alias("Lin|", [Forge.Document.Lines, Enumerable.Forge.Document.Lines])

      expected = ~q[
        alias Forge.Document.Lines
        Lin
      ]t
      assert added =~ expected
    end

    test "erlang modules are excluded" do
      {:ok, added} = add_alias(":ets|", [:ets])
      assert added =~ ":ets"
    end
  end
end
