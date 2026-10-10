defmodule Expert.Integrations.SemanticMetadata.Handlers do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Integrations
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Integrations.SemanticMetadata.Handler.Request
  alias Expert.Integrations.SemanticMetadata.Handler.Response
  alias Forge.Ast.Env
  alias Forge.Project

  require Logger

  def complete(%CursorScope{} = scope, cursor_path, %Env{} = env) do
    fields = %{context: cursor_context(env), hint: Request.hint(env)}
    decoder = &Response.completion(&1, env.document, env.position)

    scope
    |> invoke_all(:completion, cursor_path, env, fields, decoder)
    |> Response.combine_completions()
  end

  def hover(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: Request.range(env.document, range)}

    scope
    |> invoke_all(:hover, cursor_path, env, fields, &Response.hover(&1, env.document, range))
    |> Enum.concat()
  end

  def definition(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: Request.range(env.document, range)}

    scope
    |> invoke_all(:definition, cursor_path, env, fields, &Response.locations/1)
    |> Enum.concat()
  end

  def resolve(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: Request.range(env.document, range)}
    decoder = &Response.resolution(&1, env.document, range)

    scope
    |> invoke_all(:resolve, cursor_path, env, fields, decoder)
    |> Enum.find(:ignore, &(&1 != nil))
  end

  def signature_help(%CursorScope{} = scope, cursor_path, %Env{} = env) do
    scope
    |> invoke_all(:signature_help, cursor_path, env, %{}, &Response.signatures/1)
    |> Enum.concat()
  end

  def document_handlers(document, facet), do: handlers(Map.get(document, :data, []), facet)

  def references(document, handlers, %Project{} = project, entity, files) do
    request = %{entity: entity, files: files}

    :references
    |> call_handlers(document, handlers, project, request, &Response.locations/1)
    |> Enum.concat()
  end

  defp invoke_all(%CursorScope{} = scope, facet, cursor_path, env, fields, decoder) do
    case handlers(scope.data, facet) do
      [] ->
        []

      handlers ->
        request = Request.build(scope, cursor_path, env, fields)
        call_handlers(facet, scope.document, handlers, env.project, request, decoder)
    end
  end

  # Release namespacing rewrites the `:expert` atom literal to `:xp_expert`.
  # Libraries publish the key as `:expert`, so this matches it by name. Expert's
  # own documents are rewritten like this function, so they match the literal.
  defp handlers(data, facet) do
    for {key, %{facets: %{^facet => handlers}}} when is_atom(key) <- data,
        key == :expert or Atom.to_string(key) == "expert",
        is_list(handlers),
        {module, function, 1} when is_atom(module) and is_atom(function) <- handlers,
        do: {module, function}
  end

  defp call_handlers(facet, document, handlers, project, request, decoder) do
    {microseconds, results} = :timer.tc(fn -> run(document, handlers, project, request) end)

    Logger.debug("Handlers #{facet} count=#{length(handlers)} duration_us=#{microseconds}")

    for {{module, _function}, result} <- Enum.zip(handlers, results),
        {:ok, decoded} <- [decode(facet, module, result, decoder)],
        do: decoded
  end

  # The handlers of Expert's own documents are Expert code, so they run here
  # instead of in the project.
  defp run(document, handlers, project, request) do
    if document in Integrations.documents(),
      do: Enum.map(handlers, &call(&1, request)),
      else: EngineApi.call_handlers(project, handlers, [request])
  end

  defp call({module, function}, request) do
    {:ok, apply(module, function, [request])}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp decode(facet, module, {:ok, response}, decoder) do
    {:ok, decoder.(response)}
  rescue
    exception ->
      Logger.warning(
        "Handler #{facet} returned an invalid result handler=#{inspect(module)} " <>
          "result=#{inspect(response)}\n" <> Exception.format(:error, exception, __STACKTRACE__)
      )

      :error
  end

  defp decode(facet, module, {:error, message}, _decoder) do
    Logger.warning("Handler #{facet} failed handler=#{inspect(module)}\n#{message}")
    :error
  end

  defp cursor_context(%Env{} = env) do
    if Env.in_context?(env, :string), do: :string, else: :code
  end
end
