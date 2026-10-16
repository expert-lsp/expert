defmodule ExpertEEx.Metadata do
  @moduledoc false

  def document do
    %{
      contexts: [%{language_id: "eex", scope: :eex}],
      scopes: %{
        eex: %{
          entries: [],
          data: [expert: %{facets: %{completion: [{ExpertEEx, :complete, 1}]}}]
        }
      }
    }
  end
end
