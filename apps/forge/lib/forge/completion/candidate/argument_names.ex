defmodule Forge.Completion.Candidate.ArgumentNames do
  @moduledoc """
  Elixir sense, for whatever reason returns all the argument names when asked to do a completion on a function.
  This means that the arity of the function might differ from the argument names returned. Furthermore, the
  argument names have the defaults in them for some reason, which is completely unhelpful for completions.

  The functions below match the arity of the argument names to the given arity, and strip out the defaults,
  rendering the results useful for completion.
  """

  alias Future.Code, as: Code

  @type argument_names :: [String.t()]
  @default_specifier ~S(\\)

  @spec placeholders(non_neg_integer()) :: argument_names()
  def placeholders(arity), do: Enum.map(1..arity//1, &"arg#{&1}")

  @doc """
  Returns the argument names in the first of `signatures`.

  The signatures are strings from the docs chunk of a module. Without one,
  returns placeholders for `arity`.
  """
  @spec from_signatures([String.t()], non_neg_integer()) :: argument_names()
  def from_signatures([signature | _], arity) do
    case Elixir.Code.string_to_quoted(signature) do
      {:ok, {_name, _, arguments}} when is_list(arguments) ->
        Enum.map(arguments, &Macro.to_string/1)

      _error ->
        placeholders(arity)
    end
  end

  def from_signatures([], arity), do: placeholders(arity)

  @spec from_elixir_sense_map(map()) :: :error | argument_names()
  def from_elixir_sense_map(%{args_list: argument_names, arity: arity}) do
    from_elixir_sense(argument_names, arity)
  end

  def from_elixir_sense_map(%{}) do
    :error
  end

  @spec from_elixir_sense([String.t()], non_neg_integer) :: :error | argument_names()
  def from_elixir_sense(argument_names, arity) when is_list(argument_names) do
    {names, required_count} = preprocess(argument_names)

    cond do
      length(argument_names) < arity ->
        :error

      arity < required_count ->
        :error

      true ->
        generate_argument_list(names, required_count, arity)
    end
  end

  defp generate_argument_list(names, required_count, arity) do
    optional_count = arity - required_count

    {arg_list, _} =
      Enum.reduce(names, {[], optional_count}, fn
        {:required, arg_name}, {arg_list, optional_count} ->
          {[arg_name | arg_list], optional_count}

        {:optional, _}, {_arg_list, 0} = acc ->
          acc

        {:optional, arg_name}, {arg_list, optional_count} ->
          {[arg_name | arg_list], optional_count - 1}
      end)

    Enum.reverse(arg_list)
  end

  defp split_on_default(argument) do
    argument
    |> String.split(@default_specifier)
    |> Enum.map(&String.trim/1)
  end

  @spec preprocess(argument_names()) :: {[String.t()], non_neg_integer()}
  defp preprocess(argument_names) do
    {names, required_count} =
      argument_names
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {argument, index}, {names, required_count} ->
        {name, increment} =
          case split_on_default(argument) do
            [argument_name] ->
              {{:required, extract_name(argument_name, index)}, 1}

            [argument_name, _default] ->
              {{:optional, extract_name(argument_name, index)}, 0}
          end

        {[name | names], required_count + increment}
      end)

    {Enum.reverse(names), required_count}
  end

  defp extract_name(argument, index) do
    case Code.Fragment.cursor_context(argument) do
      {:unquoted_atom, atom} ->
        ":#{atom}"

      {:local_or_var, name} ->
        List.to_string(name)

      :none ->
        argument
        |> String.split("=")
        |> find_local_in_pattern_match(index)

      _ ->
        argument
    end
  end

  defp find_local_in_pattern_match([], index) do
    "arg_#{index}"
  end

  defp find_local_in_pattern_match([first | rest], index) do
    case Code.Fragment.cursor_context(first) do
      {:local_or_var, name} ->
        List.to_string(name)

      {:local_call, name} ->
        List.to_string(name)

      _ ->
        find_local_in_pattern_match(rest, index)
    end
  end
end
