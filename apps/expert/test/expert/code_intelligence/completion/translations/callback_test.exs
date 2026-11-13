defmodule Expert.CodeIntelligence.Completion.Translations.CallbackTest do
  use Expert.Test.Expert.CompletionCase

  alias Forge.Protocol.Convertible
  alias GenLSP.Enumerations.CompletionItemKind

  describe "callback completions" do
    test "suggest callbacks", %{project: project} do
      source = ~q[
        defmodule Project.Server do
          use GenServer
          def handle_inf|
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) =~
               "@impl true\ndef handle_info(${1:msg}, ${2:state}) do"
    end

    test "suggest callbacks without def", %{project: project} do
      source = ~q[
        defmodule Project.Server do
          use GenServer
          child_sp|
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(
          kind: CompletionItemKind.interface(),
          label: "child_spec(init_arg)"
        )

      assert {:ok, lsp_edits} = Convertible.to_lsp(completion.text_edit)
      assert [%{range: %{start: %{character: 2}, end: %{character: 10}}}] = List.wrap(lsp_edits)

      assert apply_completion(completion) == """
             defmodule Project.Server do
               use GenServer
               def child_spec(${1:init_arg}) do
               $0
             end
             end
             """
    end

    test "do not add parens if they're already present", %{project: project} do
      source = ~q[
        defmodule Project.Server do
          use GenServer
          def handle_inf|(msg, state)
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) =~
               "@impl true\ndef handle_info(${1:msg}, ${2:state}) do"
    end

    test "does not add second @impl if one is already present", %{project: project} do
      source = ~q[
        defmodule Project.Server do
          use GenServer
          @impl true
          def handle_inf|
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) == """
             defmodule Project.Server do
               use GenServer
               @impl true
               def handle_info(${1:msg}, ${2:state}) do
               $0
             end
             end
             """
    end
  end
end
