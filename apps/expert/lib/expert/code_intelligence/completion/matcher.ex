defmodule Expert.CodeIntelligence.Completion.Matcher do
  @moduledoc """
  Matches a completion name against the text before the cursor.

  The first characters must match. The remaining hint must occur in order, so
  `chub` matches `chunk_by`.
  """

  import Kernel, except: [match?: 2]

  @spec match?(String.t(), String.t()) :: boolean()
  def match?(_name, ""), do: true

  def match?(<<head::utf8, name::binary>>, <<head::utf8, hint::binary>>),
    do: subsequence?(name, hint)

  def match?(_name, _hint), do: false

  defp subsequence?(_name, ""), do: true
  defp subsequence?("", _hint), do: false

  defp subsequence?(<<head::utf8, name::binary>>, <<head::utf8, hint::binary>>),
    do: subsequence?(name, hint)

  defp subsequence?(<<_head::utf8, name::binary>>, hint), do: subsequence?(name, hint)
end
