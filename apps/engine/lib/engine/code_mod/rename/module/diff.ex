defmodule Engine.CodeMod.Rename.Module.Diff do
  @moduledoc """
  A module for computing the diff between old and new module names during renaming.
  """

  @doc """
  Computes the parts of the module name that need to be renamed and their replacements.

  Returns a tuple `{to_be_renamed, replacement}` where:
  - `to_be_renamed` is the suffix of the old name that needs to be changed
  - `replacement` is what it should be changed to

  ## Examples

      iex> diff("TopLevel.Parent.Child", "TopLevel.Renamed.Child")
      {"Parent", "Renamed"}

      iex> diff("TopLevel.Parent.Child", "TopLevel.Child")
      {"Parent.Child", "Child"}

      iex> diff("Foo.Bar", "Baz.Qux")
      {"Foo.Bar", "Baz.Qux"}
  """
  @spec diff(String.t(), String.t()) :: {String.t(), String.t()}
  def diff(old_name, new_name) do
    with [{:eq, eq} | _] <- String.myers_difference(old_name, new_name),
         equal_segment = trim_last_dot_part(eq),
         true <- not is_nil(equal_segment) do
      to_be_renamed = replace_leading_eq(old_name, equal_segment)
      replacement = replace_leading_eq(new_name, equal_segment)
      {to_be_renamed, replacement}
    else
      _ ->
        {old_name, new_name}
    end
  end

  defp trim_last_dot_part(module) do
    split = module |> String.reverse() |> String.split(".", parts: 2)

    if length(split) == 2 do
      [_, rest] = split
      rest |> String.reverse()
    end
  end

  defp replace_leading_eq(module, eq) do
    module |> String.replace_prefix(eq, "") |> String.trim_leading(".")
  end
end
