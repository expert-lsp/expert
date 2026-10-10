defmodule Expert.CodeIntelligence.BeamDocs do
  @moduledoc false

  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Project

  @spec fetch(Project.t(), module()) :: %{optional({atom(), atom(), arity()}) => tuple()}
  def fetch(%Project{} = project, module) when is_atom(module) do
    with path when is_binary(path) <- ModuleRegistry.beam_path(project, module),
         {:docs_v1, _anno, _language, _format, _module_doc, _metadata, entries} <-
           Code.fetch_docs(path) do
      Map.new(entries, fn {identity, _anno, signatures, docs, metadata} ->
        {identity, {signatures, docs, metadata}}
      end)
    else
      _ -> %{}
    end
  end
end
