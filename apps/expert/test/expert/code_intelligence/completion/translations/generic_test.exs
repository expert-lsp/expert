defmodule Expert.CodeIntelligence.Completion.Translations.GenericTest do
  use Expert.Test.Expert.CompletionCase
  use Patch

  alias Expert.EngineApi
  alias Forge.Completion.Candidate
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Structures.MarkupContent

  test "completes a generic candidate with its detail and documentation", %{project: project} do
    patch(EngineApi, :complete, [
      %Candidate.Generic{
        label: "email",
        detail: "Field",
        documentation: "The email field",
        kind: :field
      }
    ])

    assert {:ok, completion} =
             project
             |> complete("user.em|")
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.label == "email"
    assert completion.detail == "Field"
    assert %MarkupContent{value: "The email field"} = completion.documentation
    assert apply_completion(completion) == "user.email"
  end

  test "applies a generic snippet after the typed atom prefix", %{project: project} do
    patch(EngineApi, :complete, [
      %Candidate.Generic{
        label: "{:array, inner_type}",
        detail: "Type",
        kind: :type_parameter,
        insert_text: "array, inner_type}",
        snippet: "array, ${1:inner_type}}"
      }
    ])

    assert {:ok, completion} =
             project
             |> complete("field :tags, {:ar|")
             |> fetch_completion(kind: CompletionItemKind.type_parameter())

    assert apply_completion(completion) == "field :tags, {:array, ${1:inner_type}}"
  end
end
