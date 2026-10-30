defmodule Engine.CodeAction do
  @moduledoc """
  Handles `textDocument/codeAction` requests.

  Language clients frequently emit these while users are editing.
  """

  alias Engine.CodeAction.Handlers
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Range

  @handlers [
    Handlers.ReplaceRemoteFunction,
    Handlers.ReplaceWithUnderscore,
    Handlers.OrganizeAliases,
    Handlers.AddAlias,
    Handlers.Require,
    Handlers.RemoveUnusedAlias,
    Handlers.CreateUndefinedFunction
  ]

  @doc """
  Fans the request out to every handler whose advertised kinds and trigger kind match, and concats their actions.

  ## Options

    * `defer_edits?` - when `true`, handlers supporting deferral return actions without edits,
      carrying a `data` payload for a later `codeAction/resolve` request. Handlers without deferral
      support ignore the option and return their edits inline. Defaults to `false`.
  """
  @spec for_range(
          Document.t(),
          Range.t(),
          [Diagnostic.t()],
          [Forge.CodeAction.code_action_kind()] | :all,
          Forge.CodeAction.trigger_kind(),
          keyword()
        ) :: [Forge.CodeAction.t()]
  def for_range(%Document{} = doc, %Range{} = range, diagnostics, kinds, trigger_kind, opts \\ []) do
    Enum.flat_map(@handlers, fn handler ->
      if handle_kinds?(handler, kinds) and handle_trigger_kind?(handler, trigger_kind) do
        handler.actions(doc, range, diagnostics, opts)
      else
        []
      end
    end)
  end

  defp handle_kinds?(_handler, :all), do: true
  defp handle_kinds?(handler, kinds), do: kinds -- handler.kinds() != kinds

  defp handle_trigger_kind?(handler, trigger_kind),
    do: handler.trigger_kind() in [trigger_kind, :all]
end
