defmodule Expert.CodeIntelligence.Completion.StructFields do
  @moduledoc """
  Provides struct field completion candidates.

  Fields come from `defstruct` in the current document or a compiled BEAM.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Modules

  @doc """
  Returns the fields to write in the struct literal the cursor is in.
  """
  @spec in_literal(Context.t()) :: [struct()]
  def in_literal(%Context{} = context) do
    with {:ok, module} <- literal_module(context),
         {:ok, fields} <- fields(context, module) do
      Enum.map(fields, fn {field, _type} -> Candidate.StructField.new(field, module) end)
    else
      _ -> []
    end
  end

  @doc """
  Returns the fields to read with a dot from a value of the struct `module`.
  """
  @spec accessed(Context.t(), module(), (String.t() -> boolean())) :: [struct()]
  def accessed(%Context{} = context, module, match?) do
    case fields(context, module) do
      {:ok, fields} ->
        for {name, type} <- fields,
            match?.(name),
            do: %Candidate.StructField{
              name: name,
              origin: inspect(module),
              type_spec: type,
              call?: true
            }

      :error ->
        []
    end
  end

  defp literal_module(context) do
    Enum.find_value(context.cursor_path, :error, fn
      {:%, _, [{:__MODULE__, _, _} | _]} when not is_nil(context.module) ->
        {:ok, context.module}

      {:%, _, [{:__aliases__, _, [{:__MODULE__, _, _} | rest]} | _]}
      when not is_nil(context.module) ->
        {:ok, Module.concat([context.module | rest])}

      {:%, _, [{:__aliases__, _, segments} | _]} ->
        if Enum.all?(segments, &is_atom/1), do: {:ok, Context.expand_alias(context, segments)}

      _ ->
        nil
    end)
  end

  defp fields(context, module) do
    case Map.fetch(context.definitions, module) do
      {:ok, %{struct_fields: fields}} when is_list(fields) ->
        {:ok, Enum.map(fields, &{Atom.to_string(&1), nil})}

      _ ->
        case Modules.read(context.project, module) do
          {:ok, %{struct_fields: fields}} when is_list(fields) ->
            {:ok, fields}

          _ ->
            :error
        end
    end
  end
end
