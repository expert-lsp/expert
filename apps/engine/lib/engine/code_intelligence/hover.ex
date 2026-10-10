defmodule Engine.CodeIntelligence.Hover do
  @moduledoc """
  Hover information with ElixirSense fallback.
  """

  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  @spec hover(Document.t(), Position.t()) :: {:ok, String.t(), Range.t()} | {:error, term()}
  def hover(%Document{} = document, %Position{} = position) do
    with {:ok, _, analysis} <- Document.Store.fetch(document.uri, :analysis) do
      elixir_sense_hover(analysis, position)
    end
  end

  defp elixir_sense_hover(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Document.to_string()
    |> ElixirSense.docs(position.line, position.character)
    |> case do
      %{docs: docs, range: range} when docs != [] ->
        markdown = format_docs(docs)
        lsp_range = to_lsp_range(analysis.document, range)
        {:ok, markdown, lsp_range}

      _ ->
        {:error, :no_doc}
    end
  end

  defp format_docs(docs) do
    docs
    |> Enum.map(&format_doc/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp format_doc(%{kind: :module, module: mod, docs: docs}) do
    header = "```elixir\n#{inspect(mod)}\n```"
    join_parts([header, docs])
  end

  defp format_doc(%{
         kind: kind,
         module: mod,
         function: fun,
         args: args,
         specs: specs,
         docs: docs
       })
       when kind in [:function, :macro] do
    prefix = if kind == :macro, do: "(macro) ", else: ""
    signature = "#{prefix}#{inspect(mod)}.#{fun}(#{Enum.join(args, ", ")})"

    specs_text =
      case specs do
        [] -> ""
        _ -> Enum.join(specs, "\n")
      end

    header =
      [signature, specs_text]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    header_block = "```elixir\n#{header}\n```"
    join_parts([header_block, docs])
  end

  defp format_doc(%{kind: :type, module: mod, type: type, spec: spec, docs: docs}) do
    header_text = if mod, do: "#{inspect(mod)}.#{type}", else: "#{type}"

    header =
      [header_text, spec]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    header_block = "```elixir\n#{header}\n```"
    join_parts([header_block, docs])
  end

  defp format_doc(%{kind: :variable, name: name}) do
    "```elixir\n#{name}\n```"
  end

  defp format_doc(%{kind: :attribute, name: name, docs: docs}) do
    header = "```elixir\n@#{name}\n```"
    join_parts([header, docs])
  end

  defp format_doc(%{kind: :keyword, name: name, docs: docs}) do
    header = "```elixir\n#{name}\n```"
    join_parts([header, docs])
  end

  defp format_doc(_), do: nil

  defp join_parts(parts) do
    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp to_lsp_range(document, %{begin: {start_line, start_col}, end: {end_line, end_col}}) do
    Range.new(
      Position.new(document, start_line, start_col),
      Position.new(document, end_line, end_col)
    )
  end
end
