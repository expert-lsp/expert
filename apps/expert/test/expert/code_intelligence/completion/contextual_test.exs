defmodule Expert.CodeIntelligence.Completion.ContextualTest do
  use Expert.Test.Expert.CompletionCase
  use Patch

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata
  alias Expert.Integrations.SemanticMetadata.Completion.Result
  alias Forge.Completion.Candidate
  alias GenLSP.Structures.CompletionList

  test "contextual completions override ordinary completion", %{project: project} do
    contextual(%Result{
      mode: :override,
      candidates: [snippet("context", "contextual")],
      incomplete?: true
    })

    patch(EngineApi, :complete, [
      %Candidate.Module{name: "OrdinaryModule", full_name: "OrdinaryModule", metadata: %{}}
    ])

    assert [%{label: "context"} = item] = complete(project, "con|")
    assert apply_completion(item) == "contextual"
  end

  test "contextual completions augment ordinary completion", %{project: project} do
    contextual(%Result{
      mode: :augment,
      candidates: [snippet("context", "contextual")],
      incomplete?: true
    })

    patch(EngineApi, :complete, [
      %Candidate.Module{name: "OrdinaryModule", full_name: "OrdinaryModule", metadata: %{}}
    ])

    assert [%{label: "context"}, %{label: "OrdinaryModule"} = ordinary] =
             complete(project, "con|")

    assert apply_completion(ordinary) == "OrdinaryModule"
  end

  test "indexed callable placeholders survive contextual translation", %{project: project} do
    contextual(%Result{
      mode: :override,
      candidates: [
        %Candidate.Function{
          name: "set_attribute",
          arity: 2,
          argument_names: ["arg1", "arg2"],
          origin: "My.Builtins",
          type: :function,
          visibility: :public,
          metadata: %{}
        }
      ],
      incomplete?: true
    })

    assert [%{label: "set_attribute(arg1, arg2)"} = item] = complete(project, "set|")
    assert apply_completion(item) == "set_attribute(${1:arg1}, ${2:arg2})"
  end

  test "ignored contextual completion uses ordinary completion", %{project: project} do
    contextual(%Result{})

    patch(EngineApi, :complete, [
      %Candidate.Module{name: "OrdinaryModule", full_name: "OrdinaryModule", metadata: %{}}
    ])

    assert [%{label: "OrdinaryModule"}] = complete(project, "Ord|")
  end

  test "contextual results remain incomplete", %{project: project} do
    contextual(%Result{
      mode: :override,
      candidates: [snippet("context", "contextual")],
      incomplete?: true
    })

    assert %CompletionList{is_incomplete: true, items: [%{label: "context"}]} =
             complete(project, "con|", as_list: false)
  end

  defp snippet(label, text) do
    %Candidate.Generic{
      label: label,
      snippet: text,
      detail: "Contextual",
      kind: :field
    }
  end

  defp contextual(%Result{} = result) do
    patch(SemanticMetadata, :complete, fn env -> %Result{result | env: env} end)
  end
end
