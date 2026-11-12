defmodule Expert.Provider.Handlers.CompletionResolve do
  @moduledoc """
  Adds the documentation of a completed module or function, read from its
  BEAM when the client shows the item.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Completion.Modules
  alias Expert.Document.Context
  alias Expert.Search.Indexer.Beams
  alias GenLSP.Enumerations.MarkupKind
  alias GenLSP.Requests.CompletionItemResolve
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.MarkupContent

  @impl Expert.Provider.Handler
  def requires_engine?, do: false

  @impl Expert.Provider.Handler
  def handle(%CompletionItemResolve{params: %CompletionItem{} = item}, %Context{} = context) do
    case documentation(item.data, context) do
      doc when is_binary(doc) and doc != "" ->
        {:ok,
         %CompletionItem{
           item
           | documentation: %MarkupContent{kind: MarkupKind.markdown(), value: doc}
         }}

      _none ->
        {:ok, item}
    end
  end

  def handle(%CompletionItemResolve{params: item}, _context), do: {:ok, item}

  defp documentation(
         %{"module" => module, "name" => name, "arity" => arity, "kind" => kind},
         context
       ) do
    with {:ok, %{beam_path: beam_path}} <- Modules.compiled(context.project, module) do
      docs = Beams.function_docs(beam_path, kind, name, arity)
      [docs.summary, spec(docs.spec)] |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    end
  end

  defp documentation(%{"module" => module}, context) do
    with {:ok, %{beam_path: beam_path}} <- Modules.compiled(context.project, module) do
      Beams.module_summary(beam_path)
    end
  end

  defp documentation(_data, _context), do: nil

  defp spec(nil), do: nil
  defp spec(spec), do: "```elixir\n#{spec}\n```"
end
