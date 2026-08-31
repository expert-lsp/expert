defmodule Engine.CodeIntelligence.DeclarationTest do
  use ExUnit.Case, async: false

  alias Engine.CodeIntelligence.Declaration
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position

  defmodule RemoteBehaviour do
    @callback remote(term()) :: term()
  end

  setup do
    start_supervised!(Document.Store)
    :ok
  end

  test "finds a local behaviour callback" do
    source = """
    defmodule Example.Behaviour do
      @callback run(term()) :: term()
    end

    defmodule Example.Implementation do
      @behaviour Example.Behaviour
      def run(value), do: value
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 7, 8)
    assert location.range.start.line == 2
    assert location_line(location) =~ "@callback run"
  end

  test "finds a declaration from the callback itself" do
    source = """
    defmodule Example.Callback do
      @callback run(term()) :: term()
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 2, 14)
    assert location.range.start.line == 2
  end

  test "finds a declaration from an implementation call" do
    source = """
    defmodule Example.CallBehaviour do
      @callback run(term()) :: term()
    end

    defmodule Example.CallImplementation do
      @behaviour Example.CallBehaviour
      def run(value), do: value
    end

    Example.CallImplementation.run(:ok)
    """

    assert {:ok, %Location{} = location} = declaration(source, 10, 30)
    assert location.range.start.line == 2
  end

  test "finds a local protocol function" do
    source = """
    defprotocol Example.Protocol do
      def convert(value)
    end

    defimpl Example.Protocol, for: List do
      def convert(value), do: value
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 6, 8)
    assert location.range.start.line == 2
    assert location_line(location) =~ "def convert"
  end

  test "uses a protocol spec as the declaration" do
    source = """
    defprotocol Example.SpecProtocol do
      @spec convert(t()) :: term()
      def convert(value)
    end

    defimpl Example.SpecProtocol, for: List do
      def convert(value), do: value
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 7, 8)
    assert location.range.start.line == 2
    assert location_line(location) =~ "@spec convert"
  end

  test "finds a callback in a loaded behaviour source file" do
    source = """
    defmodule Example.RemoteImplementation do
      @behaviour #{inspect(RemoteBehaviour)}
      def remote(value), do: value
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 3, 8)
    assert location.document.path == __ENV__.file
    assert location_line(location) =~ "@callback remote"
  end

  test "selects a callback by arity" do
    source = """
    defmodule Example.Unary do
      @callback run(term()) :: term()
    end

    defmodule Example.Binary do
      @callback run(term(), term()) :: term()
    end

    defmodule Example.ArityImplementation do
      @behaviour Example.Unary
      @behaviour Example.Binary
      def run(value), do: value
    end
    """

    assert {:ok, %Location{} = location} = declaration(source, 12, 8)
    assert location.range.start.line == 2
  end

  test "returns nil when the function has no declaration" do
    source = """
    defmodule Example.Plain do
      def run(value), do: value
    end
    """

    assert {:ok, nil} = declaration(source, 2, 8)
  end

  defp declaration(source, line, character) do
    document = Document.new("file:///declaration_test.ex", source, 0)
    position = Position.new(document, line, character)
    Declaration.declaration(document, position)
  end

  defp location_line(%Location{document: document, range: range}) do
    {:ok, line} = Document.fetch_text_at(document, range.start.line)
    line
  end
end
