defmodule Expert.CodeIntelligence.Completion.Attributes do
  @moduledoc """
  Module attribute candidates: the attributes the current module sets before
  the cursor and, in the module body, the attributes Elixir reserves.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Matcher

  @reserved ~w(
    optional_callbacks behaviour impl derive enforce_keys compile deprecated
    dialyzer file external_resource on_load on_definition vsn after_compile
    after_verify before_compile fallback_to_any undefined_impl_description type
    typep opaque spec callback macrocallback typedoc doc moduledoc for protocol
    nifs
  )

  @spec matching(Context.t(), String.t()) :: [struct()]
  def matching(%Context{module: nil}, _hint), do: []

  def matching(%Context{} = context, hint) do
    set =
      case Map.fetch(context.definitions, context.module) do
        {:ok, definitions} ->
          for {name, line} <- definitions.attributes,
              is_integer(line) and line < context.line,
              do: Atom.to_string(name)

        :error ->
          []
      end

    names = if context.function?, do: set, else: set ++ @reserved

    names
    |> Enum.filter(&Matcher.match?(&1, hint))
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.map(&%Candidate.ModuleAttribute{name: "@" <> &1})
  end
end
