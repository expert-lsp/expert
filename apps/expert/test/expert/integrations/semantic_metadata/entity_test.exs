defmodule Expert.Integrations.SemanticMetadata.EntityTest do
  use Expert.Test.SemanticMetadataCase, async: false

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Entity
  alias Forge.Ast

  setup %{project: project} do
    Engine.set_project(project)

    patch(EngineApi, :resolve_entity, fn _project, analysis, position ->
      Engine.CodeIntelligence.Entity.resolve(analysis, position)
    end)

    put_documents(project, [
      %{
        contexts: [%{mfa: {My.Query, :from, 2}, argument: 1, scope: :options}],
        scopes: %{
          options: %{entries: [%{kind: :keyword, name: :where, value_scope: :expressions}]},
          expressions: %{
            entries: [],
            data: [expert: %{facets: %{resolve: [{My.Resolver, :resolve, 1}]}}]
          }
        }
      }
    ])

    :ok
  end

  test "resolves the entity that a resolve handler names", %{project: project} do
    patch(EngineApi, :call_handler, fn _project, My.Resolver, :resolve, [_request], _timeout ->
      {:ok, %{entity: %{kind: :function, module: My.Format, name: :format, arity: 1}}}
    end)

    assert {:ok, {:call, My.Format, :format, 1}, range} =
             resolve_entity(project, "My.Query.from(user in User, where: forma|t(user))")

    assert {range.start.character, range.end.character} == {36, 42}
  end

  test "resolves the Elixir source that a handler delegates to", %{project: project} do
    delegated = String.duplicate(" ", 35) <> "String.upcase(user)"

    patch(EngineApi, :call_handler, fn _project, My.Resolver, :resolve, [_request], _timeout ->
      {:ok, %{delegate: %{source: delegated}}}
    end)

    assert {:ok, {:module, String}, range} =
             resolve_entity(project, "My.Query.from(user in User, where: forma|t(user))")

    assert {range.start.character, range.end.character} == {36, 42}
  end

  test "resolves with Elixir when no handler answers", %{project: project} do
    patch(EngineApi, :call_handler, fn _project, My.Resolver, :resolve, [_request], _timeout ->
      {:ok, nil}
    end)

    assert {:ok, {:module, String}, _range} =
             resolve_entity(project, "My.Query.from(user in User, where: Stri|ng.upcase(user))")
  end

  defp resolve_entity(project, source) do
    {position, document} = pop_cursor(source, as: :document)
    Entity.resolve(project, Ast.analyze(document), position)
  end
end
