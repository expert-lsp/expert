defmodule Engine.CodeMod.Rename.Module do
  @moduledoc """
  Handles module renaming logic.

  This module is responsible for:
  - Recognizing if a position is at a module definition
  - Preparing the rename range
  - Executing the rename across all references
  """
  import Forge.Document.Line

  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeMod.Aliases
  alias Engine.CodeMod.Rename
  alias Engine.CodeMod.Rename.Entry
  alias Engine.CodeMod.Rename.Module
  alias Engine.ManagerApi
  alias Engine.Search.Indexer.Quoted
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats

  @module_defining_forms [:defmodule, :defprotocol]

  @doc """
  Checks if the position is at a module that can be renamed.
  """
  @spec recognizes?(Analysis.t(), Position.t()) :: boolean()
  def recognizes?(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, _, _} ->
        true

      _ ->
        false
    end
  end

  @doc """
  Prepares the rename operation by returning the module and the range to be renamed.
  """
  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, {:module, atom()}, Range.t()} | {:error, tuple() | atom()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    with {:ok, {:module, _module}, _range} <- resolve(analysis, position) do
      {module, range} = surround_the_whole_module(analysis, position)

      if cursor_at_declaration?(analysis, position, range) do
        {:ok, {:module, module}, range}
      else
        {:error, {:unsupported_location, :module}}
      end
    end
  end

  @doc """
  Executes the rename operation, returning a list of document changes.
  """
  @spec rename(Analysis.t(), Range.t(), String.t(), atom(), boolean()) ::
          [Document.Changes.t()] | {:error, term()}
  def rename(
        %Analysis{} = analysis,
        %Range{} = old_range,
        new_name,
        module,
        rename_files? \\ true
      ) do
    {to_be_renamed, replacement} = old_range |> range_text() |> Module.Diff.diff(new_name)
    old_name = Formats.module(module)
    target_name = String.replace_suffix(old_name, to_be_renamed, replacement)

    with {:ok, declaration} <- declaration_entry(analysis, old_range, module),
         {:ok, entries} <-
           references(declaration, module, to_be_renamed, replacement, new_name) do
      entries
      |> Enum.group_by(&Document.Path.ensure_uri(&1.path))
      |> Enum.reduce_while([], fn {uri, entries}, changes ->
        case to_document_changes(
               uri,
               entries,
               replacement,
               old_name,
               target_name,
               rename_files?
             ) do
          {:ok, document_changes} -> {:cont, [document_changes | changes]}
          {:error, {:file_already_exists, _path}} = error -> {:halt, error}
          {:error, _reason} -> {:cont, changes}
        end
      end)
      |> case do
        {:error, _reason} = error -> error
        changes -> Enum.reverse(changes)
      end
    end
  end

  defp resolve(%Analysis{} = analysis, %Position{} = position) do
    case Entity.resolve(analysis, position) do
      {:ok, {module_or_struct, module}, range} when module_or_struct in [:struct, :module] ->
        {:ok, {:module, module}, range}

      _ ->
        {:error, :not_a_module}
    end
  end

  defp resolve(path, %Position{} = position) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri),
         {:ok, _document, analysis} <- Document.Store.fetch(uri, :analysis) do
      resolve(analysis, position)
    end
  end

  defp cursor_at_declaration?(analysis, position, rename_range) do
    with {:ok, path} <- Ast.path_at(analysis, position),
         {_, _, [name | _]} <- module_declaration(path),
         {:ok, declaration_range} <- Forge.Ast.Range.fetch(name, analysis.document) do
      rename_range == declaration_range
    else
      _ -> false
    end
  end

  defp declaration_entry(analysis, range, module) do
    with {:ok, path} <- Ast.path_at(analysis, range.start),
         declaration when not is_nil(declaration) <- module_declaration(path),
         {:ok, block_range} <- Forge.Ast.Range.fetch(declaration, analysis.document) do
      {:ok,
       %Entry{
         path: analysis.document.path,
         subject: module,
         block_range: block_range,
         range: range,
         edit_range: range,
         subtype: :definition
       }}
    else
      _ -> {:error, :not_a_module_declaration}
    end
  end

  defp module_declaration(path) do
    Enum.find(
      path,
      &match?({form, _, [_ | _]} when form in @module_defining_forms, &1)
    )
  end

  defp surround_the_whole_module(analysis, position) do
    # When renaming occurs, we want users to be able to choose any place in the defining module,
    # not just the last local module, like: `defmodule |Foo.Bar do` also works.
    {:ok, %{end: {_end_line, end_character}}} = Ast.surround_context(analysis, position)
    end_position = %{position | character: end_character - 1}
    {:ok, {:module, module}, range} = resolve(analysis, end_position)
    {module, range}
  end

  defp references(declaration, module, to_be_renamed, replacement, new_name) do
    module_string = Formats.module(module)
    prefix = "#{module_string}."

    with {:ok, exact_entries} <- query_for_exacts(module),
         {:ok, descendant_entries} <- query_for_descendants(module) do
      entries =
        refresh_entries(exact_entries ++ descendant_entries, fn entry ->
          entry.type == :module and
            (Formats.module(entry.subject) == module_string or
               String.starts_with?(Formats.module(entry.subject), prefix))
        end)

      exacts =
        entries
        |> Enum.filter(
          &(&1.subtype == :reference and Formats.module(&1.subject) == module_string)
        )
        |> then(&[declaration | &1])
        |> adjust_range_for_exacts(module, to_be_renamed, replacement, new_name)

      descendants =
        entries
        |> Enum.filter(
          &(String.starts_with?(Formats.module(&1.subject), prefix) and
              entry_matching?(&1, to_be_renamed) and has_dots_in_range?(&1))
        )
        |> adjust_range_for_descendants(module, to_be_renamed)

      {:ok, exacts ++ descendants}
    end
  end

  defp query_for_exacts(module) do
    module_string = Formats.module(module)

    Engine.get_project()
    |> ManagerApi.search_store_exact(module_string, type: :module, subtype: :reference)
    |> to_entries()
  end

  defp query_for_descendants(module) do
    module_string = Formats.module(module)
    prefix = "#{module_string}."

    Engine.get_project()
    |> ManagerApi.search_store_prefix(prefix, type: :module)
    |> to_entries()
  end

  defp to_entries({:ok, entries}), do: {:ok, Enum.map(entries, &Entry.new/1)}
  defp to_entries({:error, _reason} = error), do: error
  defp to_entries([]), do: {:error, :search_store_unavailable}

  defp refresh_entries(entries, predicate) do
    entries
    |> Enum.group_by(& &1.path)
    |> Enum.flat_map(fn {path, _entries} ->
      case refresh_path(path, predicate) do
        {:ok, current} -> current
        {:error, _reason} -> []
      end
    end)
  end

  defp refresh_path(path, predicate) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _document} <- Document.Store.open_temporary(uri),
         {:ok, _document, %Analysis{valid?: true} = analysis} <-
           Document.Store.fetch(uri, :analysis),
         {:ok, current_entries} <- Quoted.index_with_cleanup(analysis) do
      current_entries =
        current_entries
        |> Enum.filter(predicate)
        |> Enum.map(&Entry.new/1)

      {:ok, current_entries}
    else
      {:ok, _document, %Analysis{valid?: false}} -> {:error, {:invalid_document, path}}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_rename_file(_document, _entries, _replacement, false), do: {:ok, nil}

  defp maybe_rename_file(document, entries, replacement, true) do
    case Enum.find(entries, &(&1.subtype == :definition)) do
      nil ->
        {:ok, nil}

      entry ->
        case Rename.File.maybe_rename(document, entry, replacement) do
          {:error, _reason} = error -> error
          rename_file -> {:ok, rename_file}
        end
    end
  end

  defp entry_matching?(entry, to_be_renamed) do
    entry.range |> range_text() |> String.contains?(to_be_renamed)
  end

  defp has_dots_in_range?(entry) do
    entry.range |> range_text() |> String.contains?(".")
  end

  defp adjust_range_for_exacts(entries, module, to_be_renamed, replacement, new_name) do
    old_suffix_length = String.length(to_be_renamed)
    old_name = Formats.module(module)
    old_leaf = old_name |> String.split(".") |> List.last()
    new_leaf = new_name |> String.split(".") |> List.last()

    Enum.flat_map(entries, fn %Entry{} = entry ->
      source = range_text(entry.range)

      cond do
        source == old_leaf ->
          entry_replacement =
            if source == old_name or entry.subtype == :definition, do: new_name, else: new_leaf

          [%{entry | replacement: entry_replacement}]

        source == to_be_renamed ->
          [%{entry | replacement: new_name}]

        String.ends_with?(source, ".#{to_be_renamed}") ->
          start_character = entry.edit_range.end.character - old_suffix_length
          entry = put_in(entry.edit_range.start.character, start_character)
          [%{entry | replacement: replacement}]

        String.contains?(source, ".") ->
          [%{entry | replacement: new_name}]

        true ->
          []
      end
    end)
  end

  defp adjust_range_for_descendants(entries, module, to_be_renamed) do
    for %Entry{} = entry <- entries,
        range_text = range_text(entry.edit_range),
        matches = matches(range_text, to_be_renamed),
        result = resolve_module_range(entry, module, matches),
        match?({:ok, _}, result) do
      {_, range} = result
      %{entry | edit_range: range}
    end
  end

  defp range_text(range) do
    line(text: text) = range.end.context_line
    String.slice(text, range.start.character - 1, range.end.character - range.start.character)
  end

  defp resolve_module_range(_entry, _module, []) do
    {:error, :not_found}
  end

  defp resolve_module_range(entry, module, [[{start, length}]]) do
    range = adjust_range_characters(entry.edit_range, {start, length})

    with {:ok, {:module, ^module}, _} <- resolve(entry.path, range.end) do
      {:ok, range}
    end
  end

  defp resolve_module_range(entry, module, [[{start, length}] | tail] = _matches) do
    # This function is mainly for the duplicated suffixes
    # For example, if we have a module named `Foo.Bar.Foo.Bar` and we want to rename it to `Foo.Bar.Baz`
    # The `Foo.Bar` will be duplicated in the range text, so we need to resolve the correct range
    # and only rename the second occurrence of `Foo.Bar`
    start_character = entry.edit_range.start.character + start
    position = %{entry.edit_range.start | character: start_character}

    with {:ok, {:module, result}, range} <- resolve(entry.path, position) do
      if result == module do
        range = adjust_range_characters(range, {start, length})
        {:ok, range}
      else
        resolve_module_range(entry, module, tail)
      end
    end
  end

  defp matches(range_text, "") do
    # When expanding a module, the to_be_renamed is an empty string,
    # so we need to scan the module before the period
    for [{start, length}] <- Regex.scan(~r/\w+(?=\.)/, range_text, return: :index) do
      [{start + length, 0}]
    end
  end

  defp matches(range_text, to_be_renamed) do
    Regex.scan(~r/#{Regex.escape(to_be_renamed)}/, range_text, return: :index)
  end

  defp adjust_range_characters(%Range{} = range, {start, length} = _matched_old_suffix) do
    start_character = range.start.character + start
    end_character = start_character + length

    range
    |> put_in([:start, :character], start_character)
    |> put_in([:end, :character], end_character)
  end

  defp to_document_changes(uri, entries, replacement, old_name, target_name, rename_files?) do
    with {:ok, _document} <- Document.Store.open_temporary(uri),
         {:ok, document, analysis, origin} <-
           Document.Store.fetch_with_origin(uri, :analysis),
         {:ok, rename_file} <-
           maybe_rename_file(document, entries, replacement, rename_files?) do
      entries = Enum.reject(entries, &explicit_alias_reference?(document, analysis, &1))

      {grouped_edits, entries} =
        grouped_alias_edits(analysis, entries, old_name, target_name)

      edits =
        entries
        |> Enum.map(&edit_for_entry(document, &1, replacement))
        |> Enum.concat(grouped_edits)
        |> Enum.sort_by(&{&1.range.start.line, &1.range.start.character}, :desc)

      expected_version = if origin == :open, do: document.version
      {:ok, Document.Changes.new(document, edits, rename_file, expected_version)}
    end
  end

  defp edit_for_entry(document, entry, replacement) do
    reference? = entry.subtype == :reference
    entry_replacement = entry.replacement || replacement

    if is_nil(entry.replacement) and reference? and
         not ancestor_is_alias?(document, entry.edit_range.start) do
      replacement = replacement |> String.split(".") |> List.last()
      Edit.new(replacement, entry.edit_range)
    else
      Edit.new(entry_replacement, entry.edit_range)
    end
  end

  defp grouped_alias_edits(%Analysis{} = analysis, entries, old_name, target_name) do
    {aliases, entries} =
      Enum.reduce(entries, {%{}, []}, fn entry, {aliases, entries} ->
        case grouped_alias_edit(analysis, entry, old_name, target_name) do
          {:ok, alias_ast, edit} ->
            {Map.put(aliases, alias_ast, edit), entries}

          :error ->
            {aliases, [entry | entries]}
        end
      end)

    {Map.values(aliases), Enum.reverse(entries)}
  end

  defp grouped_alias_edit(
         analysis,
         %Entry{subtype: :reference} = entry,
         old_name,
         target_name
       ),
       do: Aliases.rename_grouped(analysis, entry.range.start, old_name, target_name)

  defp grouped_alias_edit(_analysis, _entry, _old_name, _target_name), do: :error

  defp explicit_alias_reference?(document, analysis, %Entry{subtype: :reference} = entry) do
    source = range_text(entry.range)

    case {alias_target?(document, entry), Analysis.scopes_at(analysis, entry.range.start)} do
      {true, _scopes} ->
        false

      {false, [%Scope{} = scope | _]} ->
        scope
        |> Scope.alias_map(entry.range.start)
        |> Enum.any?(fn
          {as, %Analysis.Alias{explicit_as?: true} = alias} ->
            alias_name(as) == source and
              Analysis.Alias.to_module(alias) == entry.subject

          _alias ->
            false
        end)

      {false, []} ->
        false
    end
  end

  defp explicit_alias_reference?(_document, _analysis, _entry), do: false

  defp alias_target?(document, entry) do
    with {:ok, path} <- Ast.path_at(document, entry.range.start),
         {:alias, _, [target | _options]} <- Enum.find(path, &match?({:alias, _, _}, &1)),
         {:ok, target_range} <- Ast.Range.fetch(target, document) do
      Range.contains?(target_range, entry.range.start)
    else
      _ -> false
    end
  end

  defp alias_name(as), do: Enum.map_join(as, ".", &Atom.to_string/1)

  defp ancestor_is_alias?(%Document{} = document, %Position{} = position) do
    document
    |> Ast.cursor_path(position)
    |> Enum.any?(&match?({:alias, _, _}, &1))
  end
end
