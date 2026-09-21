defmodule Expert.Search.Indexer.Analysis.Requires do
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Require
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Position

  def at(%Analysis{} = analysis, %Position{} = position) do
    case Analysis.scopes_at(analysis, position) do
      [%Scope{} = scope | _] ->
        scope.requires
        |> Enum.filter(fn %Require{} = require ->
          require_end = require.range.end

          if require_end.line == position.line do
            require_end.character <= position.character
          else
            require_end.line < position.line
          end
        end)
        |> Enum.uniq_by(& &1.as)

      _ ->
        []
    end
  end
end
