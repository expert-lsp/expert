defmodule Forge.Search.Subject do
  @moduledoc """
  Functions for converting to a search entry's subject field
  """
  alias Forge.Formats

  def module(module) do
    module
  end

  def module_attribute(_module, attribute_name) do
    "@#{attribute_name}"
  end

  def mfa(module, function, arity) do
    Formats.mfa(module, function, arity)
  end
end
