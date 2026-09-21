defmodule Expert.Test.ExtractorCase do
  use ExUnit.CaseTemplate

  import Forge.Test.CodeSigil

  alias Expert.Search.Indexer
  alias Forge.Document

  using do
    quote do
      import Forge.Test.CodeSigil
      import Forge.Test.RangeSupport
      import unquote(__MODULE__)

      setup do
        start_supervised!(Engine.ApplicationCache)
        :ok
      end
    end
  end

  def index_everything(source) do
    do_index(source, fn entry -> entry.type != :metadata end)
  end

  def do_index(source, filter, extractors \\ nil)

  def do_index(source, filter, extractors) when is_binary(source) do
    path = "/foo/bar/baz.ex"
    doc = Document.new("file:///#{path}", source, 1)

    case Indexer.Source.index(path, source, extractors) do
      {:ok, indexed_items} ->
        indexed_items = Enum.filter(indexed_items, filter)
        {:ok, indexed_items, doc}

      error ->
        error
    end
  end

  def do_index(quoted_source, filter, extractors) do
    source_string = Macro.to_string(quoted_source)
    do_index(source_string, filter, extractors)
  end

  def in_a_module(code, module_name \\ "Parent") do
    ~q[
    defmodule #{module_name} do
      #{code}
    end
    ]
  end

  def in_a_module_function(code) do
    ~q[
      def something do
        #{code}
      end
    ]
    |> in_a_module()
  end
end
