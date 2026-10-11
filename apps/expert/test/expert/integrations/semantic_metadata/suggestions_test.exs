defmodule Expert.Integrations.SemanticMetadata.SuggestionsTest do
  use Expert.Test.SemanticMetadataCase, async: false

  alias Expert.Integrations.SemanticMetadata.Suggestions
  alias Expert.Search.Indexer.ModuleRegistry

  test "suggests the package of a library that the project uses", %{project: project} do
    register(project, Ecto.Query)

    assert [dependency] = Suggestions.dependencies(project)
    assert dependency =~ ~s({:expert_ecto, github: "expert-lsp/expert", sparse: "extensions/ecto")
  end

  test "suggests nothing for libraries that the project does not use", %{project: project} do
    assert [] = Suggestions.dependencies(project)
  end

  test "suggests nothing for a library that metadata describes", %{project: project} do
    register(project, Phoenix.Router)
    register(project, Phoenix.Component)

    put_documents(project, [
      %{
        contexts: [%{mfa: {Phoenix.Router, :get, 3}, argument: 1, scope: :routes}],
        scopes: %{routes: %{entries: []}}
      },
      %{contexts: [%{sigil: "H", scope: :markup}], scopes: %{markup: %{entries: []}}}
    ])

    assert [] = Suggestions.dependencies(project)
  end

  defp register(project, module),
    do: :ok = ModuleRegistry.put(project, module, "/#{module}.beam", :library, [])
end
