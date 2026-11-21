# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor do
  alias Sourceror.Zipper

  @type selection_or_line :: Macro.t() | pos_integer()

  @callback can_refactor?(Zipper.t(), selection_or_line) :: :skip | true | false
  @callback refactor(Zipper.t(), selection_or_line) :: Zipper.t()

  defmacro __using__(attrs) do
    works_on = Keyword.fetch!(attrs, :works_on)

    available_guard =
      case works_on do
        :line ->
          quote do
            def available?(_, selection_or_line) when not line?(selection_or_line), do: false
          end

        :selection ->
          quote do
            def available?(_, selection_or_line) when line?(selection_or_line), do: false
          end
      end

    quote do
      @behaviour Expert.Refactor

      alias Expert.Refactor.AST
      alias Sourceror.Zipper

      @dialyzer {:no_match, available?: 2, visit: 4}

      defguardp line?(selection_or_line) when is_number(selection_or_line)

      unquote(available_guard)

      def available?(zipper, selection_or_line) do
        zipper
        |> Zipper.traverse_while(false, &visit(&1, &2, selection_or_line, false))
        |> then(fn {_, available?} -> available? end)
      end

      def execute(zipper, selection_or_line) do
        zipper
        |> Zipper.traverse_while(false, &visit(&1, &2, selection_or_line, true))
        |> then(fn
          {%{node: node}, true} -> node
          {_, false} -> nil
        end)
      end

      defp visit(zipper, false, selection_or_line, refactor?) do
        # Keep this boundary opaque so generated modules do not warn on impossible clauses.
        refactorability =
          :erlang.apply(Expert.Refactor, :normalize_refactorability, [
            can_refactor?(zipper, selection_or_line)
          ])

        case refactorability do
          :skip ->
            {:skip, zipper, false}

          false ->
            {:cont, zipper, false}

          true ->
            {
              :halt,
              if(refactor?, do: refactor(zipper, selection_or_line), else: zipper),
              true
            }
        end
      end

      def refactoring(refactored \\ nil) do
        %Expert.Refactor.Refactoring{
          module: __MODULE__,
          title: unquote(Keyword.fetch!(attrs, :title)),
          kind: unquote(Keyword.fetch!(attrs, :kind)),
          refactored: refactored
        }
      end

      defdelegate placeholder, to: Expert.Refactor
    end
  end

  @refactors [
    __MODULE__.Alias.ExpandAliases,
    __MODULE__.Alias.ExtractAlias,
    __MODULE__.Alias.InlineAlias,
    __MODULE__.Alias.MergeAliases,
    __MODULE__.Alias.SortNestedAliases,
    __MODULE__.Constant.ExtractConstant,
    __MODULE__.Constant.InlineConstant,
    __MODULE__.Function.CollapseAnonymousFunction,
    __MODULE__.Function.ExpandAnonymousFunction,
    __MODULE__.Function.ExtractAnonymousFunction,
    __MODULE__.Function.ExtractFunction,
    __MODULE__.Function.InlineFunction,
    __MODULE__.Function.UseKeywordSyntax,
    __MODULE__.Function.UseRegularSyntax,
    __MODULE__.Guard.ExtractGuard,
    __MODULE__.Guard.InlineGuard,
    __MODULE__.IfElse.UseKeywordSyntax,
    __MODULE__.IfElse.UseRegularSyntax,
    __MODULE__.Pipeline.IntroduceIOInspect,
    __MODULE__.Pipeline.IntroducePipe,
    __MODULE__.Pipeline.RemoveIOInspect,
    __MODULE__.Pipeline.RemovePipe,
    __MODULE__.Variable.ExtractVariable,
    __MODULE__.Variable.InlineVariable,
    __MODULE__.Variable.UnderscoreNotUsed
  ]

  @doc """
  Lists the refactorings available for the given selection or line.
  """
  def list(zipper, selection_or_line, modules \\ @refactors) do
    Enum.reduce(modules, [], fn module, refactorings ->
      case available_refactoring(module, zipper, selection_or_line) do
        nil -> refactorings
        refactoring -> [refactoring | refactorings]
      end
    end)
  end

  @doc """
  Executes a refactor, returning it with its rewritten AST.

  `module` may be an atom or its string form, but must be one of the known refactorings;
  arbitrary module names are rejected. Unlike `list/3`, failures are not caught here — a broken
  rewrite should surface to the caller rather than be silently dropped.
  """
  def execute(zipper, selection_or_line, module) do
    with {:ok, module} <- fetch_module(module),
         refactored when refactored != nil <- module.execute(zipper, selection_or_line) do
      {:ok, module.refactoring(refactored)}
    else
      _ -> :error
    end
  end

  defp fetch_module(module) when is_atom(module) do
    if module in @refactors do
      {:ok, module}
    else
      module |> Atom.to_string() |> fetch_module()
    end
  end

  defp fetch_module(module_name) when is_binary(module_name) do
    normalized = String.replace(module_name, "Elixir.Forge.Refactor.", "Elixir.Expert.Refactor.")

    case Enum.find(@refactors, &(Atom.to_string(&1) in [module_name, normalized])) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  defp available_refactoring(module, zipper, selection_or_line) do
    if module.available?(zipper, selection_or_line),
      do: module.refactoring()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def placeholder, do: :__y__

  def normalize_refactorability(:skip), do: :skip
  def normalize_refactorability(true), do: true
  def normalize_refactorability(_), do: false
end
