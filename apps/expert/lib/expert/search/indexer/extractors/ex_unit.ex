defmodule Expert.Search.Indexer.Extractors.ExUnit do
  alias Expert.Search.Indexer.Analyzer
  alias Engine.Module.Loader
  alias Expert.Search.Indexer.Metadata
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  # setup block i.e. setup do... or setup arg do...
  def extract({setup_fn, _, args} = setup, %Reducer{} = reducer)
      when setup_fn in [:setup, :setup_all] and (is_list(args) and args != []) do
    position = Reducer.position(reducer)

    with true <- exunit_in_scope?(reducer, position),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, position) do
      arity = arity_for(args)
      subject = Formats.mfa(module, setup_fn, arity)
      setup_type = :"ex_unit_#{setup_fn}"

      case Metadata.location(setup) do
        {:block, _, _, _} -> block_entry(reducer, setup, setup_type, subject)
        {:expression, _} -> expression_entry(reducer, setup, setup_type, subject)
      end
    else
      _ -> :ignored
    end
  end

  # Test block test "test name" do ... or test "test name", arg do
  def extract({:test, _, [{_, _, [test_name]} | _] = args} = test, %Reducer{} = reducer)
      when is_binary(test_name) do
    position = Reducer.position(reducer)

    with true <- exunit_in_scope?(reducer, position),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, position) do
      arity = arity_for(args)
      module_name = Formats.module(module)
      subject = "#{module_name}.[\"#{test_name}\"]/#{arity}"

      case Metadata.location(test) do
        {:block, _, _, _} -> block_entry(reducer, test, :ex_unit_test, subject)
        {:expression, _} -> expression_entry(reducer, test, :ex_unit_test, subject)
      end
    else
      _ -> :ignored
    end
  end

  # describe blocks
  def extract({:describe, _, [{_, _, [describe_name]} | _] = args} = test, %Reducer{} = reducer)
      when is_binary(describe_name) do
    position = Reducer.position(reducer)

    with true <- exunit_in_scope?(reducer, position),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, position) do
      arity = arity_for(args)
      module_name = Formats.module(module)
      subject = "#{module_name}[\"#{describe_name}\"]/#{arity}"

      block_entry(reducer, test, :ex_unit_describe, subject)
    else
      _ -> :ignored
    end
  end

  def extract(_ign, _) do
    :ignored
  end

  defp exunit_in_scope?(%Reducer{} = reducer, %Position{} = position) do
    current_module =
      case Analyzer.current_module(reducer.analysis, position) do
        {:ok, module} -> module
        _ -> nil
      end

    exunit_module?(current_module) or
      exunit_from_uses?(reducer, position) or
      ExUnit.Case in Analyzer.requires_at(reducer.analysis, position) or
      exunit_imported?(reducer, position)
  end

  defp exunit_from_uses?(%Reducer{} = reducer, %Position{} = position) do
    uses = Analyzer.uses_at(reducer.analysis, position)

    ExUnit.Case in uses or
      ExUnit.CaseTemplate in uses or
      Enum.any?(uses, &exunit_module?/1)
  end

  defp exunit_module?(module) when is_atom(module) do
    Loader.ensure_loaded?(module) and
      (function_exported?(module, :__ex_unit__, 1) or
         function_exported?(module, :__ex_unit__, 2))
  end

  defp exunit_module?(_), do: false

  defp exunit_imported?(%Reducer{} = reducer, %Position{} = position) do
    Enum.any?(Analyzer.imports_at(reducer.analysis, position), fn {mod, _, _} ->
      mod == ExUnit.Case
    end)
  end

  defp expression_entry(%Reducer{} = reducer, ast, type, subject) do
    path = reducer.analysis.document.path
    block = Reducer.current_block(reducer)

    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    app = Engine.ApplicationCache.application(module)

    case detail_range(reducer.analysis, ast) do
      nil -> :ignored
      range -> {:ok, Entry.definition(path, block, subject, type, range, app)}
    end
  end

  defp block_entry(%Reducer{} = reducer, ast, type, subject) do
    path = reducer.analysis.document.path
    block = Reducer.current_block(reducer)

    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    app = Engine.ApplicationCache.application(module)

    case detail_range(reducer.analysis, ast) do
      nil ->
        :ignored

      detail_range ->
        {:ok,
         Entry.block_definition(
           path,
           block,
           subject,
           type,
           block_range(reducer.analysis, ast),
           detail_range,
           app
         )}
    end
  end

  defp block_range(%Analysis{} = analysis, ast) do
    case Ast.Range.fetch(ast, analysis.document) do
      {:ok, range} -> range
      _ -> nil
    end
  end

  defp detail_range(%Analysis{} = analysis, ast) do
    case Metadata.location(ast) do
      {:block, {start_line, start_column}, {do_line, do_column}, _} ->
        Range.new(
          Position.new(analysis.document, start_line, start_column),
          Position.new(analysis.document, do_line, do_column + 2)
        )

      {:expression, {start_line, start_column}} ->
        %{end: [line: end_line, column: end_column]} = Sourceror.get_range(ast)

        Range.new(
          Position.new(analysis.document, start_line, start_column),
          Position.new(analysis.document, end_line, end_column)
        )

      _ ->
        nil
    end
  end

  defp arity_for([{:__block__, _meta, labels}]) do
    length(labels)
  end

  defp arity_for(args) when is_list(args) do
    length(args)
  end
end
