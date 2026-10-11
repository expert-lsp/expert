defmodule Expert.Integrations.SemanticMetadata.Suggestions do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata
  alias Expert.Search.Indexer.ModuleRegistry

  require Logger

  @repository "expert-lsp/expert"

  @packages [
    {"expert_ecto", "extensions/ecto", Ecto.Query, mfa: Ecto.Query},
    {"expert_phoenix", "extensions/phoenix", Phoenix.Router, mfa: Phoenix.Router},
    {"expert_heex", "extensions/heex", Phoenix.Component, sigil: "H"}
  ]

  def dependencies(project) do
    documents =
      case SemanticMetadata.indexed_records(project) do
        {:ok, documents} ->
          documents

        {:error, reason} ->
          Logger.warning("Could not read semantic metadata: #{inspect(reason)}")
          []
      end

    contexts =
      for document <- documents,
          context <- document.contexts,
          do: context

    for {package, path, library_module, described_by} <- @packages,
        ModuleRegistry.beam_path(project, library_module) != nil,
        not Enum.any?(contexts, &describes?(&1, described_by)),
        do:
          ~s({:#{package}, github: "#{@repository}", sparse: "#{path}", ) <>
            ~s(only: [:dev, :test], runtime: false})
  end

  defp describes?(%{mfa: {module, _name, _arity}}, mfa: module), do: true
  defp describes?(%{sigil: sigil}, sigil: sigil), do: true
  defp describes?(_context, _described_by), do: false
end
