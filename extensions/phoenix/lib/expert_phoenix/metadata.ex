defmodule ExpertPhoenix.Metadata do
  @moduledoc false

  @verbs [:get, :post, :put, :patch, :delete, :options, :head, :connect, :trace]
  @actions [:index, :edit, :new, :show, :create, :update, :delete]

  def document do
    handler = [
      expert: %{
        facets: %{
          completion: [{ExpertPhoenix, :complete, 1}],
          resolve: [{ExpertPhoenix, :resolve, 1}]
        }
      }
    ]

    resources_doc = {Phoenix.Router, :macro, :resources, 4}

    %{
      contexts: contexts(),
      data: [expert: %{facets: %{references: [{ExpertPhoenix, :references, 1}]}}],
      scopes: %{
        controllers: %{entries: [], data: handler},
        actions: %{entries: [], data: handler},
        plugs: %{entries: [], data: handler},
        live_views: %{entries: [], data: handler},
        resources_options: %{
          entries: [
            keyword(:only, resources_doc, :resource_actions),
            keyword(:except, resources_doc, :resource_actions),
            keyword(:param, resources_doc),
            keyword(:name, resources_doc),
            keyword(:as, resources_doc),
            keyword(:singleton, resources_doc, :booleans)
          ]
        },
        resource_actions: %{entries: Enum.map(@actions, &%{kind: :literal, value: &1})},
        booleans: %{entries: [%{kind: :literal, value: true}, %{kind: :literal, value: false}]}
      }
    }
  end

  defp contexts do
    routes =
      [
        {Phoenix.Router, :match, [4, 5], [{2, :controllers}, {3, :actions}]},
        {Phoenix.Router, :forward, [2, 3, 4], [{1, :plugs}]},
        {Phoenix.Router, :resources, [2], [{1, :controllers}]},
        {Phoenix.Router, :resources, [3, 4], [{1, :controllers}, {2, :resources_options}]},
        {Phoenix.LiveView.Router, :live, [2, 3, 4], [{1, :live_views}]}
      ] ++
        for(
          verb <- @verbs,
          do: {Phoenix.Router, verb, [3, 4], [{1, :controllers}, {2, :actions}]}
        )

    for {router, route, arities, arguments} <- routes,
        arity <- arities,
        {index, scope} <- arguments,
        do: %{mfa: {router, route, arity}, argument: index, scope: scope}
  end

  defp keyword(name, doc, value_scope) do
    %{kind: :keyword, name: name, doc: doc, value_scope: value_scope}
  end

  defp keyword(name, doc), do: %{kind: :keyword, name: name, doc: doc}
end
