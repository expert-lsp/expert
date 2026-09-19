defmodule Engine.CodeMod.Aliases do
  import Forge.Document.Line

  alias Engine.CodeMod.Directives
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats

  @doc """
  Returns the aliases that are in scope at the given range.
  """
  @spec in_scope(Analysis.t(), Range.t()) :: [Alias.t()]
  def in_scope(%Analysis{} = analysis, %Range{} = range) do
    analysis
    |> Analysis.module_scope(range)
    |> aliases_in_scope()
  end

  @doc """
  Sorts the given aliases according to our rules
  """
  @spec sort(Enumerable.t(Alias.t())) :: [Alias.t()]
  def sort(aliases) do
    Enum.sort_by(aliases, fn %Alias{} = scope_alias ->
      Enum.map(scope_alias.module, fn elem -> elem |> to_string() |> String.downcase() end)
    end)
  end

  @doc """
  Returns the position in the document where aliases should be inserted
  Since a document can have multiple module definitions, the cursor position is used to
  determine the initial starting point.

  This function also returns a string that should be appended to the end of the
  edits that are performed.
  """
  @spec insert_position(Analysis.t(), Position.t()) :: {Position.t(), String.t() | nil}
  def insert_position(%Analysis{} = analysis, %Position{} = cursor_position) do
    range = Range.new(cursor_position, cursor_position)
    current_aliases = in_scope(analysis, range)
    Directives.insert_position(analysis, range, current_aliases)
  end

  @doc """
  Turns a list of aliases into aliases into edits
  """
  @spec to_edits([Alias.t()], Position.t(), trailer :: String.t() | nil) :: [Edit.t()]

  def to_edits(aliases, position, trailer \\ nil)
  def to_edits([], _, _), do: []

  def to_edits(aliases, %Position{} = insert_position, trailer) do
    Directives.to_edits(aliases, insert_position, trailer,
      render: &render_alias/1,
      sort_by: &sort_key/1,
      range: & &1.range
    )
  end

  @doc false
  def rename_grouped(%Analysis{} = analysis, %Position{} = position, old_name, target_name) do
    with {:ok, path} <- Ast.path_at(analysis, position),
         {alias_ast, base, members, options} <- Enum.find_value(path, &grouped_alias/1),
         original_names =
           Enum.map(members, &(Macro.to_string(base) <> "." <> Macro.to_string(&1))),
         names =
           Enum.map(original_names, fn name ->
             if renamed_module?(name, old_name),
               do: String.replace_prefix(name, old_name, target_name),
               else: name
           end),
         true <-
           original_names
           |> Enum.zip_with(names, &(module_parent(&1) != module_parent(&2)))
           |> Enum.any?() do
      all_moved? = Enum.all?(original_names, &renamed_module?(&1, old_name))
      range = Ast.Range.fetch!(alias_ast, analysis.document)
      parents = names |> Enum.map(&module_parent/1) |> Enum.uniq()
      same_parent? = length(parents) == 1 and List.first(parents) != []
      options = alias_options(options)
      aliases = Enum.map(names, &render_alias(&1, options))
      {:alias, metadata, _arguments} = alias_ast

      replacement =
        cond do
          all_moved? and same_parent? ->
            parent = parents |> List.first() |> Enum.join(".")
            members = Enum.map_join(names, ", ", &module_leaf/1)
            render_alias("#{parent}.{#{members}}", options)

          Keyword.has_key?(metadata, :end_of_expression) ->
            {newline, indent} = line_layout(analysis.document, range)
            Enum.join(aliases, newline <> indent)

          true ->
            "(" <> Enum.join(aliases, "; ") <> ")"
        end

      {:ok, alias_ast, Edit.new(grouped_alias_comments(analysis, range) <> replacement, range)}
    else
      _ -> :error
    end
  end

  defp aliases_in_scope(%Scope{} = scope) do
    scope.aliases
    |> Enum.filter(fn %Alias{} = scope_alias ->
      scope_alias.explicit? and Range.contains?(scope.range, scope_alias.range.start)
    end)
    |> sort()
  end

  defp join(module) do
    Enum.join(module, ".")
  end

  defp sort_key(%Alias{} = scope_alias) do
    Enum.map(scope_alias.module, fn elem -> elem |> to_string() |> String.downcase() end)
  end

  defp render_alias(%Alias{} = a) do
    if [List.last(a.module)] == a.as do
      render_alias(join(a.module), nil)
    else
      render_alias(join(a.module), "as: #{join(a.as)}")
    end
  end

  defp render_alias(module, nil), do: "alias #{module}"
  defp render_alias(module, options), do: "alias #{module}, #{options}"

  defp grouped_alias({:alias, _, [{{:., _, [base, :{}]}, _, members} | options]} = ast) do
    {ast, base, members, options}
  end

  defp grouped_alias(_ast), do: nil

  defp renamed_module?(name, old_name),
    do: name == old_name or String.starts_with?(name, old_name <> ".")

  defp grouped_alias_comments(%Analysis{} = analysis, range) do
    document = analysis.document
    {newline, indent} = line_layout(document, range)

    comments =
      for %{line: line, column: column, text: text} <- Map.values(analysis.comments_by_line),
          Range.contains?(range, Position.new(document, line, column)),
          do: {line, text}

    case Enum.sort(comments) do
      [] -> ""
      comments -> Enum.map_join(comments, newline <> indent, &elem(&1, 1)) <> newline <> indent
    end
  end

  defp alias_options([]), do: nil
  defp alias_options([options]), do: Sourceror.to_string(options, format: :splicing)

  defp line_layout(document, range) do
    {:ok, line(ending: newline)} = Document.fetch_line_at(document, range.start.line)
    {newline, String.duplicate(" ", range.start.character - 1)}
  end

  defp module_parent(module), do: module |> Formats.module() |> String.split(".") |> Enum.drop(-1)
  defp module_leaf(module), do: module |> Formats.module() |> String.split(".") |> List.last()
end
