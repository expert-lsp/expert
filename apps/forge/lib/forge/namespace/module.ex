defmodule Forge.Namespace.Module do
  @moduledoc false

  @namespace_prefix "XP"

  def prefixed?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> prefixed?()
  end

  def prefixed?("Elixir." <> rest),
    do: prefixed?(rest)

  def prefixed?(@namespace_prefix <> _),
    do: true

  def prefixed?("xp" <> _),
    do: true

  def prefixed?([?x, ?p, ?_ | _]), do: true
  def prefixed?([?E, ?l, ?i, ?x, ?i, ?r, ?., ?X, ?P | _]), do: true
  def prefixed?([?X, ?P | _]), do: true

  def prefixed?(_),
    do: false
end
