defmodule Expert.Search.Indexer.Extractors.EctoSchema do
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.Metadata
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Document.Position
  alias Forge.Search.Indexer.Entry

  def extract(
        {:schema, meta, [{:__block__, _, [_source]} | _]} = schema_block,
        %Reducer{} = reducer
      ) do
    case extract_schema_entry(schema_block, meta, reducer) do
      {:ok, _} = success -> success
      :error -> :ignored
    end
  end

  def extract(
        {:embedded_schema, meta, _} = schema_block,
        %Reducer{} = reducer
      ) do
    case extract_schema_entry(schema_block, meta, reducer) do
      {:ok, _} = success -> success
      :error -> :ignored
    end
  end

  @embeds [:embeds_one, :embeds_many]
  def extract(
        {embed_type, _, [_name, {:__aliases__, _, schema_segments} = schema_module | rest]} =
          embed,
        %Reducer{} = reducer
      )
      when embed_type in @embeds do
    document = reducer.analysis.document
    position = Reducer.position(reducer)

    with true <- block_form?(rest),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, position),
         {:ok, expanded} <- Analyzer.expand_alias(schema_segments, reducer.analysis, position),
         {:ok, block_range} <- Ast.Range.fetch(embed, document),
         {:ok, detail_range} <- Ast.Range.fetch(schema_module, document) do
      struct_module = Module.concat(module, expanded)

      definition =
        Entry.block_definition(
          document.path,
          Reducer.current_block(reducer),
          struct_module,
          :struct,
          block_range,
          detail_range,
          Engine.ApplicationCache.application(struct_module)
        )

      {:ok, definition}
    else
      _ ->
        :ignored
    end
  end

  def extract(_ast, _reducer) do
    :ignored
  end

  defp extract_schema_entry(schema_block, meta, %Reducer{} = reducer) do
    document = reducer.analysis.document
    position = Reducer.position(reducer)

    with true <- defines_schema?(reducer, position),
         {:ok, current_module} <- Analyzer.current_module(reducer.analysis, position),
         {do_line, do_column} <- Metadata.position(meta, :do),
         {:ok, range} <- Ast.Range.fetch(schema_block, document) do
      detail_range = put_in(range.end, Position.new(document, do_line, do_column + 2))

      definition_entry =
        Entry.block_definition(
          document.path,
          Reducer.current_block(reducer),
          current_module,
          :struct,
          range,
          detail_range,
          Engine.ApplicationCache.application(current_module)
        )

      {:ok, definition_entry}
    else
      _ ->
        :error
    end
  end

  defp defines_schema?(%Reducer{} = reducer, %Position{} = position) do
    Ecto.Schema in Analyzer.uses_at(reducer.analysis, position)
  end

  defp block_form?(ast) do
    {_, result} =
      Macro.prewalk(ast, false, fn
        {:__block__, _, [:do]}, false ->
          {nil, true}

        ast, acc ->
          {ast, acc}
      end)

    result
  end
end
