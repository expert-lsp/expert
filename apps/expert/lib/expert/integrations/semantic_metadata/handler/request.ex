defmodule Expert.Integrations.SemanticMetadata.Handler.Request do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Completion
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Range

  def build(%CursorScope{} = scope, cursor_path, %Env{} = env, fields) do
    Map.merge(
      %{
        aliases: aliases(env),
        imports: imports(env),
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

  defp aliases(%Env{analysis: analysis, position: position}) do
    scope_aliases =
      case Analysis.scopes_at(analysis, position) do
        [%Scope{} = scope | _] ->
          for {as, %Alias{module: segments} = alias} <- Scope.alias_map(scope, position),
              is_list(segments) and Enum.all?(segments, &is_atom/1),
              into: %{},
              do: {as, Alias.to_module(alias)}

        [] ->
          %{}
      end

    case Analysis.cursor_env_at(analysis, position) do
      %{aliases: aliases} -> Map.merge(scope_aliases, aliases)
      nil -> scope_aliases
    end
  end

  defp imports(%Env{analysis: analysis, position: position, project: project}) do
    exports = &ModuleRegistry.module_exports(project, &1)

    scope_imports =
      for {module, name, arity} <- Analyzer.imports_at(analysis, position, exports),
          do: {module, String.to_atom(name), arity}

    case Analysis.cursor_env_at(analysis, position) do
      %{imports: imports} -> Enum.uniq(imports ++ scope_imports)
      nil -> scope_imports
    end
  end
end
