defmodule Expert.Integrations.SemanticMetadata.Handler.Request do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Completion
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Range

  def build(%CursorScope{} = scope, cursor_path, %Env{} = env, fields) do
    Map.merge(
      %{
        aliases: Analyzer.aliases_at(env.analysis, env.position),
        imports:
          Analyzer.imports_at(
            env.analysis,
            env.position,
            &ModuleRegistry.module_exports(env.project, &1)
          ),
        ancestors: cursor_path,
        call: %{args: scope.arguments, ast: scope.call, target: scope.target},
        language_id: env.document.language_id,
        module: if(env.position_module != "", do: env.position_module),
        path: env.document.path,
        position: Positions.cursor(env.document, env.position),
        semantic: %{scope: scope.id, target: scope.target},
        sigil: scope.sigil,
        source: Document.to_string(env.document),
        uri: env.document.uri
      },
      fields
    )
  end

  def range(_document, nil), do: nil
  def range(%Document{} = document, %Range{} = range), do: Positions.range(document, range)

  def hint(%Env{} = env) do
    if Env.in_context?(env, :string) do
      case Regex.run(~r/[[:alnum:]_!?.\/:-]+$/u, env.prefix) do
        [hint] -> hint
        nil -> ""
      end
    else
      Completion.hint(env)
    end
  end
end
