defmodule Expert.CodeIntelligence.Symbols do
  alias Expert.Search.Indexer
  alias Expert.Search.Indexer.Extractors
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.CodeIntelligence.Symbols
  alias Forge.Document
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @block_types [
    :ex_unit_describe,
    :ex_unit_setup,
    :ex_unit_setup_all,
    :ex_unit_test,
    :module
  ]

  @symbol_extractors [
    Extractors.FunctionDefinition,
    Extractors.Module,
    Extractors.ModuleAttribute,
    Extractors.StructDefinition,
    Extractors.ExUnit
  ]

  def for_document(%Project{} = project, %Document{} = document) do
    document_entries(project, document)
  end

  defp document_entries(project, %Document{} = document) do
    analysis = Ast.analyze(document)

    entries =
      if analysis.ast == nil do
        []
      else
        Indexer.Quoted.extract_entries(analysis, @symbol_extractors, project)
      end

    definitions = Enum.filter(entries, &(&1.subtype == :definition))
    to_symbols(document, definitions)
  end

  def for_workspace(project, "") do
    case Store.all(project, subtype: :definition) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, &Symbols.Workspace.from_entry/1)}

      error ->
        error
    end
  end

  def for_workspace(project, query) do
    case Store.fuzzy(project, query, subtype: :definition) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, &Symbols.Workspace.from_entry/1)}

      error ->
        error
    end
  end

  defp to_symbols(%Document{} = document, entries) do
    entries_by_block_id = Enum.group_by(entries, & &1.block_id)
    rebuild_structure(entries_by_block_id, document, :root)
  end

  defp rebuild_structure(entries_by_block_id, %Document{} = document, block_id) do
    block_entries = Map.get(entries_by_block_id, block_id, [])

    Enum.flat_map(block_entries, fn
      %Entry{type: {:protocol, _}} = entry ->
        map_block_type(document, entry, entries_by_block_id)

      %Entry{type: {:function, type}} = entry when type in [:public, :private] ->
        map_block_type(document, entry, entries_by_block_id)

      %Entry{type: type, subtype: :definition} = entry when type in @block_types ->
        map_block_type(document, entry, entries_by_block_id)

      %Entry{} = entry ->
        case Symbols.Document.from(document, entry) do
          {:ok, symbol} -> [symbol]
          _ -> []
        end
    end)
  end

  defp map_block_type(%Document{} = document, %Entry{} = entry, entries_by_block_id) do
    result =
      if Map.has_key?(entries_by_block_id, entry.id) do
        children =
          entries_by_block_id
          |> rebuild_structure(document, entry.id)
          |> Enum.sort_by(&sort_by_start/1)
          |> group_functions()

        Symbols.Document.from(document, entry, children)
      else
        Symbols.Document.from(document, entry)
      end

    case result do
      {:ok, symbol} -> [symbol]
      _ -> []
    end
  end

  defp group_functions(children) do
    {functions, other} = Enum.split_with(children, &match?({:function, _}, &1.original_type))

    grouped_functions =
      functions
      |> Enum.group_by(fn symbol ->
        symbol.subject |> String.split(".") |> List.last() |> String.trim()
      end)
      |> Enum.map(fn
        {_name_and_arity, [definition]} ->
          definition

        {name_and_arity, [first | _] = defs} ->
          last = List.last(defs)
          [type, _] = String.split(first.name, " ", parts: 2)
          name = "#{type} #{name_and_arity}"

          children =
            Enum.map(defs, fn child ->
              [_, rest] = String.split(child.name, " ", parts: 2)
              %{child | name: rest}
            end)

          range = Range.new(first.range.start, last.range.end)
          %{first | name: name, range: range, children: children}
      end)

    grouped_functions
    |> Enum.concat(other)
    |> Enum.sort_by(&sort_by_start/1)
  end

  defp sort_by_start(%Symbols.Document{} = symbol) do
    start = symbol.range.start
    {start.line, start.character}
  end
end
