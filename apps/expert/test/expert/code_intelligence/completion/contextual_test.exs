defmodule Expert.CodeIntelligence.Completion.ContextualTest do
  use Expert.Test.Expert.CompletionCase
  use Patch

  alias Expert.EngineApi
  alias Forge.Completion.Candidate
  alias GenLSP.Structures.CompletionList

  test "contextual completions override ordinary completion", %{project: project} do
    patch(EngineApi, :contextual_completion, {
      :override,
      [{snippet("context", "contextual"), []}],
      true,
      []
    })

    patch(EngineApi, :complete, fn _project, _env -> flunk("ordinary completion ran") end)

    assert [%{label: "context"} = item] = complete(project, "con|")
    assert apply_completion(item) == "contextual"
  end

  test "contextual completions augment ordinary completion", %{project: project} do
    patch(EngineApi, :contextual_completion, {
      :augment,
      [{snippet("context", "contextual"), []}],
      true,
      [:wrap_list]
    })

    patch(EngineApi, :complete, [
      %Candidate.Module{name: "OrdinaryModule", full_name: "OrdinaryModule", metadata: %{}}
    ])

    assert [%{label: "context"}, %{label: "OrdinaryModule"} = ordinary] =
             complete(project, "con|")

    assert apply_completion(ordinary) == "[OrdinaryModule]"
  end

  test "candidate transforms apply before an override is translated", %{project: project} do
    patch(EngineApi, :contextual_completion, {
      :override,
      [{snippet(":read", ":read"), [:wrap_list]}],
      true,
      []
    })

    assert [%{label: ":read"} = item] = complete(project, ":r|")
    assert apply_completion(item) == "[:read]"
  end

  test "indexed callable placeholders survive contextual translation", %{project: project} do
    patch(EngineApi, :contextual_completion, {
      :override,
      [
        {%Candidate.Function{
           name: "set_attribute",
           arity: 2,
           argument_names: ["arg1", "arg2"],
           origin: "My.Builtins",
           type: :function,
           visibility: :public,
           metadata: %{}
         }, []}
      ],
      true,
      []
    })

    assert [%{label: "set_attribute(arg1, arg2)"} = item] = complete(project, "set|")
    assert apply_completion(item) == "set_attribute(${1:arg1}, ${2:arg2})"
  end

  test "ignored contextual completion uses ordinary completion", %{project: project} do
    patch(EngineApi, :contextual_completion, :ignore)

    patch(EngineApi, :complete, [
      %Candidate.Module{name: "OrdinaryModule", full_name: "OrdinaryModule", metadata: %{}}
    ])

    assert [%{label: "OrdinaryModule"}] = complete(project, "Ord|")
  end

  test "contextual results remain incomplete", %{project: project} do
    patch(EngineApi, :contextual_completion, {
      :override,
      [{snippet("context", "contextual"), []}],
      true,
      []
    })

    assert %CompletionList{is_incomplete: true, items: [%{label: "context"}]} =
             complete(project, "con|", as_list: false)
  end

  defp snippet(label, text) do
    %Candidate.Snippet{
      label: label,
      snippet: text,
      detail: "Contextual",
      priority: :contextual,
      kind: :field
    }
  end
end
