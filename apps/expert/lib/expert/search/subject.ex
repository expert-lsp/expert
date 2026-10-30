defmodule Expert.Search.Subject do
  @moduledoc """
  Functions for converting to a search entry's subject field
  """
  alias Forge.Formats

  defguardp is_word_char(char)
            when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_

  def module(module) when is_atom(module) do
    module
  end

  def module("Elixir"), do: "Elixir"

  def module("Elixir." <> name = full_name) do
    if Enum.all?(String.split(name, "."), &alias_segment?/1), do: name, else: quoted(full_name)
  end

  def module(name) when is_binary(name) do
    if identifier?(name), do: ":" <> name, else: quoted(name)
  end

  def module_attribute(_module, attribute_name) do
    "@#{attribute_name}"
  end

  def mfa(module, function, arity) do
    Formats.mfa(module, function, arity)
  end

  @doc """
  The key a subject is stored and compared under.
  """
  def key(subject) when is_binary(subject), do: subject
  def key(subject) when is_atom(subject), do: inspect(subject)

  defp quoted(name), do: ":" <> inspect(name)

  defp alias_segment?(<<first, rest::binary>>) when first in ?A..?Z, do: alias_chars?(rest)
  defp alias_segment?(_segment), do: false

  defp alias_chars?(<<char, rest::binary>>) when is_word_char(char), do: alias_chars?(rest)
  defp alias_chars?(<<>>), do: true
  defp alias_chars?(_rest), do: false

  defp identifier?(<<first, rest::binary>>)
       when first in ?A..?Z or first in ?a..?z or first == ?_,
       do: identifier_chars?(rest)

  defp identifier?(_name), do: false

  defp identifier_chars?(<<char, rest::binary>>) when is_word_char(char) or char == ?@,
    do: identifier_chars?(rest)

  defp identifier_chars?(<<char>>) when char in [??, ?!], do: true
  defp identifier_chars?(<<>>), do: true
  defp identifier_chars?(_rest), do: false
end
