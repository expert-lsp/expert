defmodule Expert.Provider.Handlers.CodeActionResolve do
  @moduledoc """
  Resolves the `edit` for a deferred code action produced by
  `Expert.Provider.Handlers.CodeAction` when the client supports `codeAction/resolve`.

  The action's `data` payload identifies the document (uri and version), the original request
  range, and the refactoring to execute. The request is routed through the standard
  document-request pipeline (via the `data` uri), so by the time it reaches this handler the
  engine is known to be ready and `context` holds the current document and its project.

  Edits are computed against the current document. If the document changed since the action was
  listed, or the refactoring no longer applies, the resolve is rejected with `ContentModified`.

  A code action that isn't one of ours is echoed back unchanged.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.Refactor
  alias Forge.Document
  alias Forge.Document.Line
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Enumerations.ErrorCodes
  alias GenLSP.Enumerations.LSPErrorCodes
  alias GenLSP.Requests.CodeActionResolve
  alias GenLSP.Structures.CodeAction
  alias GenLSP.Structures.WorkspaceEdit

  require Line

  @impl Expert.Provider.Handler
  def handle(%CodeActionResolve{params: %CodeAction{} = action}, context) do
    case resolve(action, context) do
      {:ok, %CodeAction{} = resolved} -> {:ok, resolved}
      {:error, reason} -> {:ok, error_response(reason)}
    end
  end

  defp resolve(
         %CodeAction{data: %{"provider" => "refactor"} = data} = action,
         %Context{document: document, project: project}
       ) do
    with {:ok, payload} <- Forge.CodeAction.from_refactor_data(data),
         :ok <- check_version(document, payload.version),
         {:ok, range} <- build_range(document, payload.range),
         {:ok, changes} <- resolve_changes(project, document, range, payload.module) do
      edit = %WorkspaceEdit{changes: %{document.uri => changes}}
      {:ok, %CodeAction{action | edit: edit}}
    end
  end

  # Not one of our deferred actions (or no document context) — per LSP, echo the
  # action back unchanged when there is nothing to resolve.
  defp resolve(%CodeAction{} = action, _context) do
    {:ok, action}
  end

  defp check_version(%Document{version: version}, version), do: :ok
  defp check_version(_document, _version), do: {:error, :stale_code_action}

  defp resolve_changes(project, document, range, module_name) do
    case Refactor.CodeAction.resolve(project, document, range, module_name) do
      {:ok, changes} -> {:ok, changes}
      _ -> {:error, :refactoring_no_longer_available}
    end
  end

  defp build_range(document, {start_coord, end_coord}) do
    with {:ok, start_pos} <- build_position(document, start_coord),
         {:ok, end_pos} <- build_position(document, end_coord),
         :ok <- validate_order(start_pos, end_pos) do
      {:ok, Range.new(start_pos, end_pos)}
    end
  end

  # from_refactor_data guarantees integer coordinates, but we validate them against
  # the current document rather than trust them: an out-of-bounds line/character
  # would otherwise crash deep in Document.fragment. Position.new rejects an
  # out-of-range line (valid?: false) but does not check the character against the
  # line's length, so we bound the character here.
  defp build_position(document, {line, character}) when character >= 1 do
    case Position.new(document, line, character) do
      %Position{valid?: true, context_line: context_line} = position ->
        if character <= line_length(context_line) + 1 do
          {:ok, position}
        else
          {:error, :invalid_range}
        end

      _ ->
        {:error, :invalid_range}
    end
  end

  defp build_position(_document, _coord), do: {:error, :invalid_range}

  defp validate_order(start_pos, end_pos) do
    case Position.compare(start_pos, end_pos) do
      :gt -> {:error, :invalid_range}
      _ -> :ok
    end
  end

  defp line_length(context_line) do
    context_line |> Line.line(:text) |> String.length()
  end

  defp error_response(:stale_code_action) do
    content_modified("The document changed after the code action was requested")
  end

  defp error_response(:refactoring_no_longer_available) do
    content_modified("The refactoring no longer applies to the document")
  end

  defp error_response(:invalid_range) do
    invalid_params("The code action targeted an invalid range")
  end

  defp error_response(:invalid_data) do
    invalid_params("The code action carried malformed data")
  end

  defp content_modified(message) do
    %GenLSP.ErrorResponse{code: LSPErrorCodes.content_modified(), message: message}
  end

  defp invalid_params(message) do
    %GenLSP.ErrorResponse{code: ErrorCodes.invalid_params(), message: message}
  end
end
