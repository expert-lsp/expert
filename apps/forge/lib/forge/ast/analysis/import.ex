defmodule Forge.Ast.Analysis.Import do
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Range

  defstruct module: nil, selector: :all, range: nil, explicit?: true

  @type function_name :: atom()
  @type function_arity :: {function_name(), arity()}
  @type selector ::
          :functions
          | :macros
          | :sigils
          | [only: [function_arity()]]
          | [except: [function_arity()]]
  @type t :: %{
          module: module(),
          selector: selector(),
          line: non_neg_integer()
        }
  def new(%Document{} = document, ast, module) do
    %__MODULE__{module: module, range: Ast.Range.get(ast, document)}
  end

  def new(%Document{} = document, ast, module, selector) do
    %__MODULE__{
      module: module,
      selector: expand_selector(selector),
      range: Ast.Range.get(ast, document)
    }
  end

  def implicit(%Range{} = range, module) do
    %__MODULE__{module: module, range: range, explicit?: false}
  end

  defp expand_selector(selectors) when is_list(selectors) do
    selectors =
      Enum.reduce(selectors, [], fn
        {{:__block__, _, [type]}, {:__block__, _, [selector]}}, acc
        when type in [:only, :except] ->
          expanded =
            case selector do
              :functions ->
                :functions

              :macros ->
                :macros

              :sigils ->
                :sigils

              keyword when is_list(keyword) ->
                keyword
                |> Enum.reduce([], &expand_function_keywords/2)
                |> Enum.reverse()

              _ ->
                # they're likely in the middle of typing in something, and have produced an
                # invalid import
                []
            end

          [{type, expanded} | acc]

        _, acc ->
          acc
      end)

    if selectors == [] do
      :all
    else
      selectors
    end
  end

  # If the selectors is not valid, like: `import SomeModule, o `,  we default to :all
  defp expand_selector(_) do
    :all
  end

  defp expand_function_keywords(
         {{:__block__, _, [function_name]}, {:__block__, _, [arity]}},
         acc
       )
       when is_atom(function_name) and is_number(arity) do
    [{function_name, arity} | acc]
  end

  defp expand_function_keywords(_ignored, acc),
    do: acc

  def to_module(%__MODULE__{module: module}), do: Module.concat(module)
end
