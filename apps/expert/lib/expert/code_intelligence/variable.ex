defmodule Expert.CodeIntelligence.Variable do
  alias Expert.Search.Indexer
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry

  @extractors [Indexer.Extractors.Variable]

  @spec definition(Analysis.t(), Position.t(), atom()) :: {:ok, Entry.t()} | :error
  def definition(%Analysis{} = analysis, %Position{} = position, variable_name) do
    with {:ok, block_structure, entries} <- index_variables(analysis),
         {:ok, %Entry{} = definition_entry} <-
           do_find_definition(variable_name, block_structure, entries, position) do
      {:ok, definition_entry}
    else
      _ ->
        :error
    end
  end

  @spec references(Analysis.t(), Position.t(), atom(), boolean()) :: [Range.t()]
  def references(
        %Analysis{} = analysis,
        %Position{} = position,
        variable_name,
        include_definitions? \\ false
      ) do
    with {:ok, block_structure, entries} <- index_variables(analysis),
         {:ok, entries} <-
           references_in(entries, block_structure, position, variable_name, include_definitions?) do
      entries
    else
      _ -> []
    end
  end

  defp references_in(entries, block_structure, position, variable_name, include_definitions?) do
    case do_find_definition(variable_name, block_structure, entries, position) do
      {:ok, %Entry{} = definition_entry} ->
        references = search_for_references(entries, definition_entry, block_structure)

        entries =
          if include_definitions? do
            [definition_entry | references]
          else
            references
          end

        entries =
          Enum.sort_by(entries, fn %Entry{} = entry ->
            {entry.range.start.line, entry.range.start.character}
          end)

        {:ok, entries}

      _ ->
        :error
    end
  end

  defp index_variables(%Analysis{} = analysis) do
    with {:ok, entries} <- Indexer.Quoted.index(analysis, @extractors),
         {[block_structure], entries} <- Enum.split_with(entries, &(&1.type == :metadata)) do
      {:ok, block_structure.subject, entries}
    end
  end

  defp do_find_definition(variable_name, block_structure, entries, position) do
    with {:ok, entry} <- fetch_entry(entries, variable_name, position) do
      search_for_definition(entries, entry, block_structure)
    end
  end

  defp fetch_entry(entries, variable_name, position) do
    entries
    |> Enum.find(fn %Entry{} = entry ->
      entry.subject == variable_name and entry.type == :variable and
        Range.contains?(entry.range, position)
    end)
    |> case do
      %Entry{} = entry ->
        {:ok, entry}

      _ ->
        :error
    end
  end

  defp search_for_references(entries, %Entry{} = definition_entry, block_structure) do
    block_id_to_children = block_id_to_children(block_structure)

    definition_children = Map.get(block_id_to_children, definition_entry.block_id, [])

    # The algorithm here is to first clean up the entries so they either are definitions or references to a
    # variable with the given name. We sort them by their occurrence in the file, working backwards on a line, so
    # definitions earlier in the line shadow definitions later in the line.
    # Then we start at the definition entry, and then for each entry after that,
    # if it's a definition, we mark the state as being shadowed, but reset the state if the block
    # id isn't in the children of the current block id. If we're not in a child of the current block
    # id, then we're no longer shadowed
    #
    # Note, this algorithm doesn't work when we have a block definition whose result rebinds a variable.
    # For example:
    # entries = [4, 5, 6]
    # entries =
    #  if something() do
    #    [1 | entries]
    #  else
    #    entries
    # end
    # Searching for the references to the initial variable won't find anything inside the block, but
    # searching for the rebound variable will.

    {entries, _, _} =
      entries
      |> Enum.filter(fn %Entry{} = entry ->
        after_definition? = Position.compare(entry.range.start, definition_entry.range.end) == :gt

        variable_type? = entry.type == :variable
        correct_subject? = entry.subject == definition_entry.subject
        child_of_definition_block? = entry.block_id in definition_children

        variable_type? and correct_subject? and child_of_definition_block? and after_definition?
      end)
      |> Enum.sort_by(fn %Entry{} = entry ->
        start = entry.range.start
        {start.line, -start.character, entry.block_id}
      end)
      |> Enum.reduce({[], false, definition_entry.block_id}, fn
        %Entry{subtype: :definition} = entry, {entries, _, _} ->
          # we have a definition that's shadowing our definition entry
          {entries, true, entry.block_id}

        %Entry{subtype: :reference} = entry, {entries, true, current_block_id} ->
          shadowed? = entry.block_id in Map.get(block_id_to_children, current_block_id, [])

          entries =
            if shadowed? do
              entries
            else
              [entry | entries]
            end

          {entries, shadowed?, entry.block_id}

        %Entry{} = entry, {entries, false, _} ->
          # we're a reference and we're not being shadowed; collect it and move on.
          {[entry | entries], false, entry.block_id}
      end)

    entries
  end

  defp search_for_definition(entries, %Entry{} = entry, block_structure) do
    block_id_to_parents = collect_parents(block_structure)
    block_path = Map.get(block_id_to_parents, entry.block_id)
    entries_by_block_id = entries_by_block_id(entries)

    Enum.reduce_while([entry.block_id | block_path], :error, fn block_id, _ ->
      block_entries =
        entries_by_block_id
        |> Map.get(block_id, [])
        |> then(fn entries ->
          # In the current block, reject all entries that come after the entry whose definition
          # we're searching for. This prevents us from finding definitions who are shadowing
          # our entry. For example, the definition on the left of the equals in: `param = param + 1`.

          if block_id == entry.block_id do
            Enum.drop_while(entries, &(&1.id != entry.id))
          else
            entries
          end
        end)

      case Enum.find(block_entries, &definition_of?(entry, &1)) do
        %Entry{} = definition ->
          {:halt, {:ok, definition}}

        nil ->
          {:cont, :error}
      end
    end)
  end

  defp definition_of?(%Entry{} = needle, %Entry{} = compare) do
    compare.type == :variable and compare.subtype == :definition and
      compare.subject == needle.subject
  end

  defp entries_by_block_id(entries) do
    entries
    |> Enum.reduce(%{}, fn %Entry{} = entry, acc ->
      Map.update(acc, entry.block_id, [entry], &[entry | &1])
    end)
    |> Map.new(fn {block_id, entries} ->
      entries =
        Enum.sort_by(
          entries,
          fn %Entry{} = entry ->
            {entry.range.start.line, -entry.range.start.character}
          end,
          :desc
        )

      {block_id, entries}
    end)
  end

  def block_id_to_parents(hierarchy) do
    hierarchy
    |> flatten_hierarchy()
    |> Enum.reduce(%{}, fn {parent_id, child_id}, acc ->
      old_parents = [parent_id | Map.get(acc, parent_id, [])]
      Map.update(acc, child_id, old_parents, &Enum.concat(&1, old_parents))
    end)
    |> Map.put(:root, [])
  end

  def block_id_to_children(hierarchy) do
    # Note: Parent ids are included in their children list in order to simplify
    # checks for "is this id in one of its children"

    hierarchy
    |> flatten_hierarchy()
    |> Enum.reverse()
    |> Enum.reduce(%{root: [:root]}, fn {parent_id, child_id}, current_mapping ->
      current_children = [child_id | Map.get(current_mapping, child_id, [parent_id])]

      current_mapping
      |> Map.put_new(child_id, [child_id])
      |> Map.update(parent_id, current_children, &Enum.concat(&1, current_children))
    end)
  end

  def flatten_hierarchy(hierarchy) do
    Enum.flat_map(hierarchy, fn
      {k, v} when is_map(v) and map_size(v) > 0 ->
        v
        |> Map.keys()
        |> Enum.map(&{k, &1})
        |> Enum.concat(flatten_hierarchy(v))

      _ ->
        []
    end)
  end

  defp collect_parents(block_structure) do
    do_collect_parents(block_structure, %{}, [])
  end

  defp do_collect_parents(hierarchy, parent_map, path) do
    Enum.reduce(hierarchy, parent_map, fn {block_id, children}, acc ->
      parent_map = Map.put(acc, block_id, path)
      do_collect_parents(children, parent_map, [block_id | path])
    end)
  end
end
