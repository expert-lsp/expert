defmodule Expert.CodeIntelligence.Completion.Translations.GenericTest do
  use Expert.Test.Expert.CompletionCase
  use Patch

  alias Expert.EngineApi
  alias Forge.Completion.Candidate
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Structures.MarkupContent

  test "generic Ecto fields are completed", %{project: project} do
    patch(EngineApi, :complete, [
      %Candidate.Generic{
        label: "email",
        detail: "Ecto field",
        documentation: "The email field",
        kind: :field
      }
    ])

    assert {:ok, completion} =
             project
             |> complete("user.em|")
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.label == "email"
    assert completion.detail == "Ecto field"
    assert %MarkupContent{value: "The email field"} = completion.documentation
    assert apply_completion(completion) == "user.email"
  end

  test "generic Ecto type snippets preserve the atom prefix", %{project: project} do
    patch(EngineApi, :complete, [
      %Candidate.Generic{
        label: "{:array, inner_type}",
        detail: "Ecto type",
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
