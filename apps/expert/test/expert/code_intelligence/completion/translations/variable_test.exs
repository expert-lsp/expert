defmodule Expert.CodeIntelligence.Completion.Translations.VariableTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  test "variables are completed", %{project: project} do
    source = ~q[
      def my_function do
        stinky = :smelly
        st|
      end
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert completion.label == "stinky"
    assert completion.detail == "stinky"

    assert apply_completion(completion) == ~q[
      def my_function do
        stinky = :smelly
        stinky
      end
    ]
  end

  test "all variables are returned", %{project: project} do
    source = ~q[
    def my_function do
      var_1 = 3
      var_2 = 5
      va|
    end
    ]

    assert {:ok, [c1, c2]} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert c1.label == "var_1"
    assert c2.label == "var_2"
  end

  test "the pin operator is kept when nothing is typed after it", %{project: project} do
    source = ~q[
      def my_function(result) do
        stinky = :smelly
        {:ok, ^|} = result
      end
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion("stinky")

    assert apply_completion(completion) == ~q[
      def my_function(result) do
        stinky = :smelly
        {:ok, ^stinky} = result
      end
    ]
  end
end
