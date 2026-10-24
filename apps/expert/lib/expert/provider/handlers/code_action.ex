defmodule Expert.Provider.Handlers.CodeAction do
  @behaviour Expert.Provider.Handler

  alias Expert.Configuration
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Refactor
  alias Forge.CodeAction
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentCodeAction{params: %Structures.CodeActionParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context
    diagnostics = Enum.map(params.context.diagnostics, &to_code_action_diagnostic/1)
    defer_edits? = Configuration.client_resolves_code_action_edits?()
    only = params.context.only || :all
    trigger_kind = params.context.trigger_kind

    engine_actions =
      EngineApi.code_actions(
        project,
        document,
        params.range,
        diagnostics,
        only,
        trigger_kind,
        defer_edits?: defer_edits?
      )

    refactor_actions =
      Refactor.CodeAction.actions(
        project,
        document,
        params.range,
        diagnostics,
        only,
        trigger_kind,
        defer_edits?: defer_edits?
      )

    results = Enum.map(engine_actions ++ refactor_actions, &to_result/1)

    {:ok, results}
  end

  defp to_code_action_diagnostic(%Structures.Diagnostic{} = diagnostic) do
    %CodeAction.Diagnostic{
      range: diagnostic.range,
      message: diagnostic.message,
      source: diagnostic.source
    }
  end

  # Deferred action: the edit is computed on codeAction/resolve, identified by the data payload
  # the client round-trips back to us.
  defp to_result(%CodeAction{changes: nil, data: data} = action) when not is_nil(data) do
    %Structures.CodeAction{
      title: action.title,
      kind: action.kind,
      data: data
    }
  end

  defp to_result(%CodeAction{} = action) do
    %Structures.CodeAction{
      title: action.title,
      kind: action.kind,
      edit: %Structures.WorkspaceEdit{changes: %{action.uri => action.changes}}
    }
  end
end
