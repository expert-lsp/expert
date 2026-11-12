defmodule Expert.CodeIntelligence.Completion.Fields do
  @moduledoc """
  Field candidates after `variable.`, when the variable was last bound to a
  struct or map literal, as in `user = %User{}` or `%User{} = user`.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Matcher
  alias Expert.CodeIntelligence.Completion.StructFields

  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]

  @spec after_dot(Context.t(), atom(), String.t()) :: [struct()]
  def after_dot(%Context{} = context, variable, hint) do
    match? = &Matcher.match?(&1, hint)

    case binding(context, variable) do
      {:struct, module} ->
        StructFields.accessed(context, module, match?)

      {:map, keys} ->
        for key <- keys,
            name = Atom.to_string(key),
            match?.(name),
            do: %Candidate.MapField{name: name, call?: true}

      nil ->
        []
    end
  end

  # The cursor path ends in the code before the cursor, so the last binding
  # found in the enclosing definition is the one in effect.
  defp binding(context, variable) do
    scope =
      Enum.find(context.cursor_path, List.last(context.cursor_path), fn
        {form, _, _} -> form in @definitions
        _ -> false
      end)

    {_scope, binding} =
      Macro.prewalk(scope, nil, fn
        {:=, _, [left, right]} = node, binding ->
          {node,
           bound(left, right, variable, context) || bound(right, left, variable, context) ||
             binding}

        node, binding ->
          {node, binding}
      end)

    binding
  end

  defp bound({variable, _, context}, value, variable, completion) when is_atom(context),
    do: literal(value, completion)

  defp bound(_pattern, _value, _variable, _context), do: nil

  defp literal({:%, _, [{:__MODULE__, _, _}, {:%{}, _, _}]}, %Context{module: module})
       when not is_nil(module),
       do: {:struct, module}

  defp literal({:%, _, [{:__aliases__, _, segments}, {:%{}, _, _}]}, context) do
    if Enum.all?(segments, &is_atom/1),
      do: {:struct, Context.expand_alias(context, segments)}
  end

  defp literal({:%{}, _, pairs}, _context) do
    keys =
      for {key, _value} <- pairs,
          key = unwrap(key),
          is_atom(key),
          do: key

    {:map, keys}
  end

  defp literal(_value, _context), do: nil

  defp unwrap({:__block__, _, [literal]}), do: literal
  defp unwrap(literal), do: literal
end
