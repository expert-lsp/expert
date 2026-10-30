defmodule Expert.Refactor.CodeActionTest do
  use Forge.Test.CodeMod.Case
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.RangeSupport

  alias Expert.EngineApi
  alias Expert.Refactor.CodeAction
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  def apply_code_mod(original_text, _ast, options) do
    document = Document.new("file:///file.ex", original_text, 0)

    changes =
      nil
      |> CodeAction.actions(document, options[:range], [], :all, :all)
      |> Enum.find(&(&1.title == options[:title]))
      |> then(& &1.changes.edits)

    {:ok, changes}
  end

  defp assert_refactored(title, original, refactored) do
    {range, original} = pop_range(original)
    assert {:ok, ^refactored} = modify(original, range: range, title: title)
  end

  test "Refactorex works with the cursor position" do
    assert_refactored(
      "Underscore variables not used",
      ~q[
        def my_«»func(unused) do
        end
      ],
      ~q[
        def my_func(_unused) do
        end]
    )
  end

  test "Refactorex works with a selection" do
    assert_refactored(
      "Extract variable",
      ~q[
        def my_func() do
          «42»
        end
      ],
      ~q[
        def my_func() do
          extracted_variable = 42
          extracted_variable
        end]
    )
  end

  test "Refactorex works with a multiline position" do
    assert_refactored(
      "Extract anonymous function",
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, «fn i ->
            i + 20
          end»)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, &extracted_function(&1))
        end

        defp extracted_function(i) do
          i + 20
        end
      end]
    )
  end

  test "Refactorex respects formatter line length" do
    patch(EngineApi, :formatter_opts, fn _project, _path ->
      [line_length: 120, locals_without_parens: []]
    end)

    assert_refactored(
      "Remove pipe",
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          «»map |> Map.merge(other)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          Map.merge(map, other)
        end
      end]
    )
  end

  test "Refactorex formats when formatter line length is missing" do
    patch(EngineApi, :formatter_opts, fn _project, _path ->
      [locals_without_parens: []]
    end)

    assert_refactored(
      "Remove pipe",
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          «»map |> Map.merge(other)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func(
              %{} = map,
              %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other
            ) do
          Map.merge(map, other)
        end
      end]
    )
  end

  describe "deferred edits and resolve" do
    test "defers edits when requested and resolves them to the eager result" do
      original =
        ~q[
        defmodule Foo do
          def my_func(a, b) do
            «»a |> foo(b)
          end
        end
        ]
        |> String.trim()

      {range, text} = pop_range(original)
      document = Document.new("file:///file.ex", text, 0)

      eager_actions = CodeAction.actions(nil, document, range, [], :all, :all)

      deferred_actions =
        CodeAction.actions(nil, document, range, [], :all, :all, defer_edits?: true)

      assert eager_actions != []
      assert length(eager_actions) == length(deferred_actions)

      for {eager, deferred} <- Enum.zip(eager_actions, deferred_actions) do
        assert eager.title == deferred.title
        assert eager.kind == deferred.kind
        assert eager.changes != nil
        assert deferred.changes == nil
        assert deferred.data != nil

        assert deferred.data == %{
                 "provider" => "refactor",
                 "uri" => document.uri,
                 "version" => 0,
                 "module" => deferred.data["module"],
                 "range" => %{
                   "start" => %{"line" => range.start.line, "character" => range.start.character},
                   "end" => %{"line" => range.end.line, "character" => range.end.character}
                 }
               }

        assert {:ok, changes} = CodeAction.resolve(nil, document, range, deferred.data["module"])
        assert changes == eager.changes
      end
    end

    test "resolve returns :error for unknown modules" do
      document = Document.new("file:///file.ex", "a |> b()", 0)
      range = Range.new(Position.new(document, 1, 1), Position.new(document, 1, 1))

      assert :error = CodeAction.resolve(nil, document, range, "Elixir.NotARefactoring")
      assert :error = CodeAction.resolve(nil, document, range, "NotARefactoring")

      assert {:ok, _} =
               CodeAction.resolve(
                 nil,
                 document,
                 range,
                 "Elixir.Expert.Refactor.Pipeline.RemovePipe"
               )

      assert {:ok, _} =
               CodeAction.resolve(
                 nil,
                 document,
                 range,
                 "Elixir.Forge.Refactor.Pipeline.RemovePipe"
               )
    end

    test "resolve returns :error when the range no longer applies" do
      document = Document.new("file:///file.ex", "a |> b()", 0)
      applies_range = Range.new(Position.new(document, 1, 1), Position.new(document, 1, 1))

      does_not_apply_range =
        Range.new(Position.new(document, 1, 1), Position.new(document, 1, 5))

      actions = CodeAction.actions(nil, document, applies_range, [], :all, :all)
      remove_pipe = Enum.find(actions, &(&1.title == "Remove pipe"))
      assert remove_pipe != nil

      assert :error =
               CodeAction.resolve(
                 nil,
                 document,
                 does_not_apply_range,
                 "Elixir.Expert.Refactor.Pipeline.RemovePipe"
               )
    end
  end
end
