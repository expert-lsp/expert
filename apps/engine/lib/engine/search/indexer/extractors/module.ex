defmodule Engine.Search.Indexer.Extractors.Module do
  @moduledoc """
  Extracts module references and definitions from AST
  """

  alias Engine.Search.Indexer.Metadata
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  require Logger

  @definition_mappings %{
    defmodule: :module,
    defprotocol: {:protocol, :definition}
  }
  @module_definitions Map.keys(@definition_mappings)

  # extract a module definition
  def extract(
        {definition, defmodule_meta,
         [{:__aliases__, module_name_meta, module_name}, module_block]} = defmodule_ast,
        %Reducer{} = reducer
      )
      when definition in @module_definitions do
    %Block{} = block = Reducer.current_block(reducer)

    with {:ok, aliased_module} <- resolve_alias(reducer, module_name),
         {:ok, detail_range} <- module_range(reducer, module_name, module_name_meta) do
      entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          block,
          Subject.module(aliased_module),
          @definition_mappings[definition],
          block_range(reducer.analysis.document, defmodule_ast),
          detail_range,
          Engine.ApplicationCache.application(aliased_module)
        )

      module_name_meta = Reducer.skip(module_name_meta)

      elem =
        {:defmodule, defmodule_meta,
         [{:__aliases__, module_name_meta, module_name}, module_block]}

      {:ok, entry, elem}
    else
      _ -> :ignored
    end
  end

  # Keyword-do syntax puts `for:` and `do:` in one list; split them for the extractor below.
  def extract(
        {:defimpl, metadata, [protocol, [for_block, {{:__block__, _, [:do]}, _} = body]]},
        %Reducer{} = reducer
      ) do
    extract({:defimpl, metadata, [protocol, [for_block], [body]]}, reducer)
  end

  # defimpl MyProtocol, for: MyStruct do ...
  def extract(
        {:defimpl, _, [{:__aliases__, _, module_name}, [for_block], _impl_body]} = defimpl_ast,
        %Reducer{} = reducer
      ) do
    %Block{} = block = Reducer.current_block(reducer)

    with {:ok, protocol_module} <- resolve_alias(reducer, module_name),
         {:ok, for_target} <- resolve_for_block(reducer, for_block),
         {:ok, detail_range} <- defimpl_range(reducer, defimpl_ast) do
      implemented_module = Module.concat(protocol_module, for_target)

      implementation_entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          block,
          Subject.module(protocol_module),
          {:protocol, :implementation},
          block_range(reducer.analysis.document, defimpl_ast),
          detail_range,
          Engine.ApplicationCache.application(protocol_module)
        )

      module_entry =
        Entry.copy(implementation_entry,
          subject: Subject.module(implemented_module),
          type: :module
        )

      {:ok, [implementation_entry, module_entry]}
    else
      _ ->
        :ignored
    end
  end

  # This matches an elixir module reference
  def extract({:__aliases__, metadata, maybe_module}, %Reducer{} = reducer)
      when is_list(maybe_module) do
    with {:ok, module} <- module(reducer, maybe_module),
         {:ok, range} <- module_range(reducer, maybe_module, metadata) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry, nil}
    else
      _ -> :ignored
    end
  end

  @module_length String.length("__MODULE__")
  # This matches __MODULE__ references
  def extract({:__MODULE__, metadata, _} = ast, %Reducer{} = reducer) do
    line = Sourceror.get_line(ast)
    pos = Position.new(reducer.analysis.document, line - 1, 1)

    with {:ok, current_module} <- Engine.Analyzer.current_module(reducer.analysis, pos),
         {:ok, start_pos, end_pos} <- module_positions(reducer, metadata) do
      range = Range.new(start_pos, end_pos)
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(current_module),
          :module,
          range,
          Engine.ApplicationCache.application(current_module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  # This matches an erlang module, which is just an atom
  def extract({:__block__, metadata, [atom_literal]}, %Reducer{} = reducer)
      when is_atom(atom_literal) do
    with {:ok, module} <- module(reducer, atom_literal),
         {:ok, range} <- module_range(reducer, module, metadata) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  # Function capture with arity: &OtherModule.foo/3
  def extract(
        {:&, _,
         [
           {:/, _,
            [
              {{:., _, [{:__aliases__, start_metadata, maybe_module}, _function_name]}, _, []},
              _
            ]}
         ]},
        %Reducer{} = reducer
      ) do
    with {:ok, module} <- module(reducer, maybe_module),
         {:ok, range} <- module_range(reducer, maybe_module, start_metadata) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end

  defp defimpl_range(%Reducer{} = reducer, {_, protocol_meta, _} = protocol_ast) do
    start = Sourceror.get_start_position(protocol_ast)

    case Metadata.position(protocol_meta, :do) do
      {finish_line, finish_column} ->
        # add two to include the do
        finish_column = finish_column + 2
        document = reducer.analysis.document

        range =
          Range.new(
            Position.new(document, start[:line], start[:column]),
            Position.new(document, finish_line, finish_column)
          )

        {:ok, range}

      nil ->
        case protocol_ast do
          {:defimpl, _, [_, _, [{{:__block__, do_meta, [:do]}, _}]]} ->
            document = reducer.analysis.document

            {:ok,
             Range.new(
               Position.new(document, start[:line], start[:column]),
               Position.new(document, do_meta[:line], do_meta[:column] + 3)
             )}

          _ ->
            :error
        end
    end
  end

  defp resolve_for_block(
         %Reducer{} = reducer,
         {{:__block__, _, [:for]}, {:__aliases__, _, for_target}}
       ) do
    resolve_alias(reducer, for_target)
  end

  defp resolve_for_block(_, _), do: :error

  defp resolve_alias(%Reducer{} = reducer, unresolved_alias) do
    position = Reducer.position(reducer)

    Engine.Analyzer.expand_alias(unresolved_alias, reducer.analysis, position)
  end

  defp module(%Reducer{} = reducer, maybe_module) when is_list(maybe_module) do
    with true <- Enum.all?(maybe_module, &module_part?/1),
         {:ok, resolved} <- resolve_alias(reducer, maybe_module) do
      {:ok, resolved}
    else
      _ ->
        human_location = Reducer.human_location(reducer)

        Logger.warning(
          "Could not expand module #{inspect(maybe_module)}. Please report this (at #{human_location})"
        )

        :error
    end
  end

  defp module(%Reducer{}, maybe_erlang_module) when is_atom(maybe_erlang_module) do
    if Engine.ApplicationCache.available_module?(maybe_erlang_module) do
      {:ok, maybe_erlang_module}
    else
      :error
    end
  end

  defp module(_, _), do: :error

  @protocol_module_attribute_names [:protocol, :for]

  @starts_with_capital ~r/[A-Z]+/
  defp module_part?(part) when is_atom(part) do
    Regex.match?(@starts_with_capital, Atom.to_string(part))
  end

  defp module_part?({:@, _, [{type, _, _} | _]}) when type in @protocol_module_attribute_names,
    do: true

  defp module_part?({:__MODULE__, _, context}) when is_atom(context), do: true

  defp module_part?(_), do: false

  defp module_range(%Reducer{} = reducer, module_name, metadata) do
    case Metadata.position(metadata) do
      {line, column} -> {:ok, to_range(reducer, module_name, {line, column})}
      nil -> :error
    end
  end

  defp module_positions(%Reducer{} = reducer, metadata) do
    case Metadata.position(metadata) do
      {start_line, start_col} ->
        start_pos = Position.new(reducer.analysis.document, start_line, start_col)
        end_pos = Position.new(reducer.analysis.document, start_line, start_col + @module_length)
        {:ok, start_pos, end_pos}

      nil ->
        :error
    end
  end

  # handles @protocol and @for in defimpl blocks
  defp to_range(%Reducer{} = reducer, [{:@, _, [{type, _, _} | _]} = attribute | segments], _)
       when type in @protocol_module_attribute_names do
    range = Sourceror.get_range(attribute)

    document = reducer.analysis.document
    module_length = segments |> Ast.Module.name() |> String.length()
    # add one because we're off by the @ sign
    end_column = range.end[:column] + module_length + 1

    Range.new(
      Position.new(document, range.start[:line], range.start[:column]),
      Position.new(document, range.end[:line], end_column)
    )
  end

  defp to_range(%Reducer{} = reducer, module_name, {line, column}) do
    document = reducer.analysis.document

    module_length =
      module_name
      |> Ast.Module.name()
      |> String.length()

    Range.new(
      Position.new(document, line, column),
      Position.new(document, line, column + module_length)
    )
  end

  defp block_range(document, ast) do
    case Ast.Range.fetch(ast, document) do
      {:ok, range} -> range
      _ -> nil
    end
  end
end
