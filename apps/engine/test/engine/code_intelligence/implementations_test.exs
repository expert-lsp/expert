defmodule Engine.CodeIntelligence.ImplementationsTest do
  use ExUnit.Case, async: false

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.RangeSupport

  alias Engine.CodeIntelligence.Implementations
  alias Forge.Document

  defmodule Behaviour do
    @callback run(term()) :: term()
  end

  defmodule BehaviourImplementation do
    @behaviour Behaviour

    @impl true
    def run(value), do: value
  end

  defprotocol Renderable do
    def render(value)
  end

  defimpl Renderable, for: List do
    def render(value), do: value
  end

  defmodule DelegateTarget do
    def original(value), do: value
    def with_default(value, _option), do: value
  end

  setup_all do
    start_supervised!(Document.Store)
    :ok
  end

  test "returns no implementations for unsupported contexts" do
    for source <- [
          "|",
          "__MOD|ULE__",
          "Eli|xir",
          "DoesNotExist|",
          "String.up|case(\"value\")",
          ":ets.ne|w(:table, [])"
        ] do
      assert {:ok, []} = implementations(source), source
    end
  end

  test "finds behaviour callback implementations" do
    source = "Engine.CodeIntelligence.ImplementationsTest.Behaviour.ru|n(:value)"

    assert {:ok, [location]} = implementations(source)
    assert decorate(location.document, location.range) == "    «def run(value), do: value»"
  end

  test "finds behaviour modules and callbacks defined in the current buffer" do
    sources = [
      {~q"""
         defmodule BufferBehav|iour do
           @callback run(term()) :: term()
         end

         defmodule BufferBehaviourImplementation do
           @behaviour BufferBehaviour
           def run(value), do: value
         end
       """,
       "«defmodule BufferBehaviourImplementation do\n  @behaviour BufferBehaviour\n  def run(value), do: value\nend»"},
      {~q"""
         defmodule BufferBehaviour do
           @callback run(term()) :: term()
         end

         defmodule BufferBehaviourImplementation do
           @behaviour BufferBehaviour
           def run(value), do: value
         end

         BufferBehaviour.ru|n(:value)
       """, "  «def run(value), do: value»"}
    ]

    for {source, expected} <- sources do
      assert {:ok, [location]} = implementations(source)
      assert decorate(location.document, location.range) == expected
    end
  end

  test "finds protocol modules and functions defined in the current buffer" do
    sources = [
      {~q"""
         defprotocol BufferProto|col do
           def render(value)
         end

         defimpl BufferProtocol, for: List do
           def render(value), do: value
         end
       """, "«defimpl BufferProtocol, for: List do\n  def render(value), do: value\nend»"},
      {~q"""
         defprotocol BufferProtocol do
           def render(value)
         end

         defimpl BufferProtocol, for: List do
           def render(value), do: value
         end

         BufferProtocol.ren|der([])
       """, "  «def render(value), do: value»"}
    ]

    for {source, expected} <- sources do
      assert {:ok, [location]} = implementations(source)
      assert decorate(location.document, location.range) == expected
    end
  end

  test "finds protocol functions through aliases and module attributes" do
    for source <- [
          ~q"""
            alias Engine.CodeIntelligence.ImplementationsTest.Renderable, as: R
            R.ren|der([])
          """,
          ~q"""
            defmodule Caller do
              @protocol Engine.CodeIntelligence.ImplementationsTest.Renderable
              @protocol.ren|der([])
            end
          """
        ] do
      assert {:ok, [location]} = implementations(source)

      assert decorate(location.document, location.range) ==
               "    «def render(value), do: value»"
    end
  end

  test "finds protocol functions from specs and implementation functions" do
    sources = [
      ~q"""
        defprotocol SpecProtocol do
          @spec ren|der(t()) :: term()
          def render(value)
        end

        defimpl SpecProtocol, for: Atom do
          def render(value), do: value
        end
      """,
      ~q"""
        defimpl Engine.CodeIntelligence.ImplementationsTest.Renderable, for: Atom do
          def ren|der(value), do: value
        end
      """
    ]

    for {source, expected} <-
          Enum.zip(sources, [
            "  «def render(value), do: value»",
            "    «def render(value), do: value»"
          ]) do
      assert {:ok, locations} = implementations(source)

      assert Enum.any?(locations, fn location ->
               decorate(location.document, location.range) == expected
             end)
    end
  end

  test "handles incomplete protocol calls and rejects invalid arities" do
    assert {:ok, [location]} =
             implementations("Engine.CodeIntelligence.ImplementationsTest.Renderable.ren|der(")

    assert decorate(location.document, location.range) ==
             "    «def render(value), do: value»"

    assert {:ok, []} =
             implementations(
               "Engine.CodeIntelligence.ImplementationsTest.Renderable.ren|der(:one, "
             )
  end

  test "follows renamed delegates and delegates with default arguments" do
    sources = [
      {~q"""
         defmodule Delegate do
           defdelegate forw|arded(value),
             to: Engine.CodeIntelligence.ImplementationsTest.DelegateTarget,
             as: :original
         end
       """, "    «def original(value), do: value»"},
      {~q"""
         defmodule Delegate do
           defdelegate with_de|fault(value, option \\ :default),
             to: Engine.CodeIntelligence.ImplementationsTest.DelegateTarget,
             as: :with_default
         end
       """, "    «def with_default(value, _option), do: value»"}
    ]

    for {source, expected} <- sources do
      assert {:ok, [location]} = implementations(source)
      assert decorate(location.document, location.range) == expected
    end
  end

  test "follows delegates defined in the current buffer" do
    source = ~q"""
      defmodule BufferDelegateTarget do
        def original(value), do: value
      end

      defmodule BufferDelegate do
        defdelegate forwarded(value), to: BufferDelegateTarget, as: :original
      end

      BufferDelegate.for|warded(:value)
    """

    assert {:ok, [location]} = implementations(source)

    assert decorate(location.document, location.range) ==
             "  «def original(value), do: value»"
  end

  test "does not recurse forever through recursive delegates" do
    source = ~q"""
      defmodule RecursiveDelegate do
        defdelegate forw|arded(value), to: RecursiveDelegate
      end
    """

    assert {:ok, []} = implementations(source)
  end

  defp implementations(source) do
    {position, source} = pop_cursor(source)
    uri = "file:///implementation_subject_#{System.unique_integer([:positive])}.ex"
    :ok = Document.Store.open(uri, source, 1)
    {:ok, document} = Document.Store.fetch(uri)

    Implementations.implementations(document, position)
  end
end
