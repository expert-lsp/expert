# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.NameCache do
  def store_name(new_name) when is_bitstring(new_name) do
    new_name
    |> String.replace(~r/[^a-zA-Z0-9_?!]/, "")
    |> String.to_atom()
    |> store_name()
  end

  def store_name(new_name), do: Process.put(__MODULE__, new_name)

  def consume_name_or(namer_fn),
    do: Process.delete(__MODULE__) || namer_fn.()
end
