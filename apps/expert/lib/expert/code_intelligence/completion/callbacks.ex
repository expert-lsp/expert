defmodule Expert.CodeIntelligence.Completion.Callbacks do
  @moduledoc """
  Provides callback and overridable function completion candidates.

  Candidates come from the compiled module and `@behaviour` attributes in the
  current document.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Definitions
  alias Expert.CodeIntelligence.Completion.Matcher
  alias Expert.CodeIntelligence.Completion.Modules

  @spec matching(Context.t(), String.t()) :: [struct()]
  def matching(%Context{module: nil}, _hint), do: []

  def matching(%Context{} = context, hint) do
    compiled =
      case Modules.read(context.project, context.module) do
        {:ok, details} -> details
        :error -> nil
      end

    callbacks =
      for behaviour <- behaviours(context, compiled),
          callback <- callbacks(context, behaviour),
          matches?(callback, hint),
          do: candidate(callback, behaviour)

    implemented = MapSet.new(callbacks, &{&1.name, &1.arity})

    overridable =
      for %{name: name, arity: arity} = injected <- (compiled && compiled.injected) || [],
          {name, arity} not in implemented,
          matches?(injected, hint),
          do: candidate(injected, injected.metadata.context)

    Enum.sort_by(callbacks, &{&1.name, &1.arity}) ++
      Enum.sort_by(overridable, &{&1.name, &1.arity})
  end

  defp behaviours(context, compiled) do
    declared =
      case Map.fetch(context.definitions, context.module) do
        {:ok, %Definitions{} = definitions} ->
          Enum.flat_map(definitions.behaviours, &behaviour(context, &1))

        :error ->
          []
      end

    Enum.uniq(declared ++ ((compiled && compiled.behaviours) || []))
  end

  defp behaviour(context, {:__aliases__, _, segments}) do
    if Enum.all?(segments, &is_atom/1),
      do: [inspect(Context.expand_alias(context, segments))],
      else: []
  end

  defp behaviour(_context, {:__block__, _, [module]}) when is_atom(module), do: [inspect(module)]
  defp behaviour(_context, _behaviour), do: []

  defp callbacks(context, behaviour) do
    case Enum.find(context.definitions, fn {module, _} -> inspect(module) == behaviour end) do
      {_module, %Definitions{} = definitions} ->
        for callback <- definitions.callbacks do
          callback
          |> Map.take([:kind, :arity, :arguments, :summary, :spec])
          |> Map.merge(%{name: Atom.to_string(callback.name), metadata: %{}})
        end

      nil ->
        case Modules.read(context.project, behaviour) do
          {:ok, details} -> details.callbacks
          :error -> []
        end
    end
  end

  # A partial `def` or `defmacro` matches all applicable callbacks.
  defp matches?(callable, hint) do
    def_prefix =
      if callable.kind in [:macrocallback, :macro], do: "defmacro", else: "def"

    String.starts_with?(def_prefix, hint) or Matcher.match?(callable.name, hint)
  end

  defp candidate(callable, origin) do
    %Candidate.Callback{
      argument_names: callable.arguments,
      arity: callable.arity,
      metadata: callable.metadata,
      name: callable.name,
      origin: origin,
      spec: callable.spec,
      summary: callable.summary,
      type: :callback
    }
  end
end
