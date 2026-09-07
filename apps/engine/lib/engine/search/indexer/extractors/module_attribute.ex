defmodule Engine.Search.Indexer.Extractors.ModuleAttribute do
  @moduledoc """
  Extracts module attribute definitions and references from AST
  """

  alias Engine.Analyzer
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry

  # Finds module attribute usages
  def extract({:@, _, [{attr_name, _, nil}]}, %Reducer{} = reducer) do
    block = Reducer.current_block(reducer)

    case Analyzer.current_module(reducer.analysis, Reducer.position(reducer)) do
      {:ok, current_module} ->
        reference =
          Entry.reference(
            reducer.analysis.document.path,
            block,
            Subject.module_attribute(current_module, attr_name),
            :module_attribute,
            reference_range(reducer, attr_name),
            Engine.ApplicationCache.application(current_module)
          )

        {:ok, reference}

      :error ->
        :ignored
    end
  end

  # an attribute being typed above an already existing attribute will have the name `@`, which we ignore
  # example:
  # @|
  # @callback foo() :: :ok
  def extract({:@, _, [{:@, _, _attr_value}]}, %Reducer{}) do
    :ignored
  end

  # Finds module attribute definitions @foo 3
  def extract({:@, _, [{attr_name, _, attr_value}]} = attr, %Reducer{} = reducer) do
    block = Reducer.current_block(reducer)

    case Analyzer.current_module(reducer.analysis, Reducer.position(reducer)) do
      {:ok, current_module} ->
        definition =
          Entry.definition(
            reducer.analysis.document.path,
            block,
            Subject.module_attribute(current_module, attr_name),
            :module_attribute,
            definition_range(reducer, attr),
            Engine.ApplicationCache.application(current_module)
          )

        value =
          if attr_name in [:spec, :type, :typep, :opaque, :callback, :macrocallback] do
            Macro.prewalk(attr_value, fn
              {name, meta, args} when name not in [:__aliases__, :__MODULE__, :__block__] ->
                {name, Reducer.skip(meta), args}

              ast ->
                ast
            end)
          else
            attr_value
          end

        {:ok, definition, value}

      _ ->
        :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end

  defp reference_range(%Reducer{} = reducer, attr_name) do
    document = reducer.analysis.document

    name_length =
      attr_name
      |> Atom.to_string()
      |> String.length()

    {start_line, start_column} = reducer.position

    # add 1 to include the @ character
    end_column = start_column + name_length + 1

    Range.new(
      Position.new(document, start_line, start_column),
      Position.new(document, start_line, end_column)
    )
  end

  defp definition_range(%Reducer{} = reducer, attr_ast) do
    document = reducer.analysis.document

    [line: start_line, column: start_column] = Sourceror.get_start_position(attr_ast)

    end_line = Sourceror.get_end_line(attr_ast)
    {:ok, line_text} = Forge.Document.fetch_text_at(document, end_line)
    # add one because lsp positions are one-based
    end_column = String.length(line_text) + 1

    Range.new(
      Position.new(document, start_line, start_column),
      Position.new(document, end_line, end_column)
    )
  end
end
