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

  test "parameters of an unfinished anonymous function are completed", %{project: project} do
    source = ~q[
      def my_function(entries) do
        Enum.map(entries, fn entry ->
          ent|
    ]

    assert {:ok, [entries, entry]} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert entries.label == "entries"
    assert entry.label == "entry"
  end

  test "variables are not completed after a module", %{project: project} do
    source = ~q[
      def my_function do
        stinky = :smelly
        Enum.|
      end
    ]

    assert {:error, :not_found} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.variable())
  end

  test "variables are completed after a pin", %{project: project} do
    source = ~q[
      def my_function(expected, actual) do
        case actual do
          ^|
        end
      end
    ]

    assert {:ok, [actual, expected]} =
             project
             |> complete(source, trigger_character: "^")
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert actual.label == "actual"
    assert expected.label == "expected"
  end

  test "variables are completed in a bitstring size but not as a modifier", %{project: project} do
    size = ~q[
      def my_function(data, length) do
        <<header::size(len|), _::binary>> = data
      end
    ]

    modifier = ~q[
      def my_function(data, length) do
        <<header::bin|>> = data
      end
    ]

    assert {:ok, completions} =
             project
             |> complete(size)
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert "length" in Enum.map(completions, & &1.label)

    assert {:error, :not_found} =
             project
             |> complete(modifier)
             |> fetch_completion(kind: CompletionItemKind.variable())
  end

  test "variables are not filtered by the typed prefix", %{project: project} do
    source = ~q[
      def my_function do
        stinky = :smelly
        zz|
      end
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.variable())

    assert completion.label == "stinky"
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
end
