defmodule Expert.Integrations.SemanticMetadata.Handlers do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Integrations.SemanticMetadata.Common
  alias Expert.Integrations.SemanticMetadata.CursorScope
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.ModuleRegistry
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project

  require Logger

  @handler_timeout 10_000
  @item_limit 500
  @kinds Candidate.Generic.kinds()

  def complete(%CursorScope{} = scope, cursor_path, %Env{} = env) do
    fields = %{context: cursor_context(env), hint: hint(env)}

    scope
    |> invoke_all(:completion, cursor_path, env, fields, &decode_completion/1)
    |> result()
  end

  def hover(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: range_map(range)}

    scope
    |> invoke_all(:hover, cursor_path, env, fields, &decode_hover(&1, env.document, range))
    |> Enum.concat()
  end

  def definition(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: range_map(range)}

    scope
    |> invoke_all(:definition, cursor_path, env, fields, &decode_locations/1)
    |> Enum.concat()
  end

  def resolve(%CursorScope{} = scope, cursor_path, %Env{} = env, identifier, range) do
    fields = %{identifier: identifier, range: range_map(range)}

    scope
    |> invoke_all(:resolve, cursor_path, env, fields, &decode_resolution(&1, env.document, range))
    |> Enum.find(:ignore, &(&1 != nil))
  end

  def signature_help(%CursorScope{} = scope, cursor_path, %Env{} = env) do
    scope
    |> invoke_all(:signature_help, cursor_path, env, %{}, &decode_signatures/1)
    |> Enum.concat()
  end

  def document_handlers(documents, facet) do
    documents
    |> Enum.flat_map(&handlers(Map.get(&1, :data, []), facet))
    |> Enum.uniq()
  end

  def references(handlers, %Project{} = project, entity, files) do
    request = %{entity: entity, files: files}

    for handler <- handlers,
        {:ok, locations} <- [
          call_handler(:references, handler, project, request, &decode_locations/1)
        ],
        location <- locations,
        do: location
  end

  defp invoke_all(%CursorScope{} = scope, facet, cursor_path, env, fields, decoder) do
    case handlers(scope.data, facet) do
      [] ->
        []

      handlers ->
        request = Map.merge(request(scope, cursor_path, env), fields)

        for handler <- handlers,
            {:ok, result} <- [call_handler(facet, handler, env.project, request, decoder)],
            do: result
    end
  end

  # Release namespacing rewrites the `:expert` atom literal to `:xp_expert`.
  # Libraries publish the key as `:expert`, so this matches it by name.
  defp handlers(data, facet) do
    for {key, %{facets: %{^facet => handlers}}} when is_atom(key) <- data,
        Atom.to_string(key) == "expert",
        is_list(handlers),
        {module, function, 1} when is_atom(module) and is_atom(function) <- handlers,
        do: {module, function}
  end

  defp call_handler(facet, {module, function}, project, request, decoder) do
    arguments = [project, module, function, [request], @handler_timeout]
    {microseconds, result} = :timer.tc(EngineApi, :call_handler, arguments)
    Logger.debug("Handler #{facet} handler=#{inspect(module)} duration_us=#{microseconds}")

    case result do
      {:ok, response} ->
        decode(facet, module, response, decoder)

      {:error, message} ->
        Logger.warning("Handler #{facet} failed handler=#{inspect(module)}\n#{message}")
        :error
    end
  end

  defp decode(facet, module, response, decoder) do
    {:ok, decoder.(response)}
  rescue
    exception ->
      Logger.warning(
        "Handler #{facet} returned an invalid result handler=#{inspect(module)} " <>
          "result=#{inspect(response)}\n" <> Exception.format(:error, exception, __STACKTRACE__)
      )

      :error
  end

  defp request(%CursorScope{} = scope, cursor_path, %Env{} = env) do
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
      position: %{line: env.position.line, character: env.position.character},
      semantic: %{scope: scope.id, target: scope.target},
      sigil: scope.sigil,
      source: Document.to_string(env.document),
      uri: env.document.uri
    }
  end

  defp range_map(nil), do: nil

  defp range_map(%Range{start: start, end: stop}) do
    %{
      start: %{line: start.line, character: start.character},
      end: %{line: stop.line, character: stop.character}
    }
  end

  defp cursor_context(%Env{} = env) do
    if Env.in_context?(env, :string), do: :string, else: :code
  end

  # `Code.Fragment.cursor_context/1` reads the text of a string as code, so
  # `"user.cr` looks like a call on `user`. In a string, the hint is instead
  # the name characters right before the cursor.
  defp hint(%Env{} = env) do
    if Env.in_context?(env, :string) do
      case Regex.run(~r/[[:alnum:]_!?.\/:-]+$/u, env.prefix) do
        [hint] -> hint
        nil -> ""
      end
    else
      Common.hint(env)
    end
  end

  defp decode_completion(items) when is_list(items),
    do: %{mode: :augment, candidates: decode_items(items), incomplete?: true}

  defp decode_completion(%{delegate: %{source: source}}) when is_binary(source),
    do: {:delegate, %{source: source}}

  defp decode_completion(%{items: items} = response) do
    %{
      mode: completion_mode(Map.get(response, :mode, :augment)),
      candidates: decode_items(items),
      incomplete?: boolean(Map.get(response, :incomplete?, true))
    }
  end

  defp completion_mode(mode) when mode in [:augment, :override], do: mode

  defp boolean(value) when is_boolean(value), do: value

  defp decode_items(items) when is_list(items),
    do: items |> Enum.take(@item_limit) |> Enum.map(&decode_item/1)

  defp decode_item(%{insert_text: _text, snippet: _snippet}),
    do: raise(ArgumentError, "an item has both :insert_text and :snippet")

  defp decode_item(%{label: label, kind: kind} = item) when is_binary(label) and kind in @kinds do
    candidate = %Candidate.Generic{
      label: label,
      kind: kind,
      range: decode_range(Map.get(item, :range)),
      filter_text: text(item, :filter_text) || label,
      insert_text: text(item, :insert_text),
      snippet: text(item, :snippet),
      detail: text(item, :detail),
      documentation: text(item, :documentation)
    }

    {candidate, []}
  end

  defp text(map, key) do
    case Map.get(map, key) do
      nil -> nil
      text when is_binary(text) -> text
    end
  end

  # An LSP completion item can only replace text on one line.
  defp decode_range(nil), do: nil

  defp decode_range(%{
         start: %{line: line, character: start_character},
         end: %{line: line, character: end_character}
       })
       when is_integer(line) and is_integer(start_character) and is_integer(end_character) and
              start_character <= end_character,
       do: {line, start_character, end_character}

  defp decode_hover(nil, _document, _range), do: []
  defp decode_hover("", _document, _range), do: []
  defp decode_hover(markdown, _document, range) when is_binary(markdown), do: [{markdown, range}]

  defp decode_hover(%{contents: markdown, range: range}, document, _range)
       when is_binary(markdown),
       do: [{markdown, document_range(document, range)}]

  defp decode_resolution(nil, _document, _identifier_range), do: nil

  defp decode_resolution(%{delegate: %{source: source}}, _document, _identifier_range)
       when is_binary(source),
       do: {:delegate, %{source: source}}

  defp decode_resolution(%{entity: entity} = response, document, identifier_range) do
    range =
      case response do
        %{range: range} -> document_range(document, range)
        %{} -> identifier_range
      end

    {:entity, decode_entity(entity), range}
  end

  defp decode_entity(%{kind: kind, module: module} = entity)
       when kind in [:module, :struct] and is_atom(module) and map_size(entity) == 2,
       do: entity

  defp decode_entity(%{kind: kind, module: module, name: name, arity: arity} = entity)
       when kind in [:function, :macro, :type] and is_atom(module) and is_atom(name) and
              is_integer(arity) and arity >= 0 and map_size(entity) == 4,
       do: entity

  defp decode_locations(locations) when is_list(locations) do
    locations
    |> Enum.take(@item_limit)
    |> Enum.map(fn %{path: path, range: range} when is_binary(path) ->
      uri = Document.Path.ensure_uri(path)
      {:ok, document} = Document.Store.open_temporary(uri)
      Location.new(document_range(document, range), uri)
    end)
  end

  defp document_range(document, %{
         start: %{line: start_line, character: start_character},
         end: %{line: end_line, character: end_character}
       })
       when is_integer(start_line) and is_integer(start_character) and is_integer(end_line) and
              is_integer(end_character) and
              {start_line, start_character} <= {end_line, end_character} do
    Range.new(
      Position.new(document, start_line, start_character),
      Position.new(document, end_line, end_character)
    )
  end

  defp decode_signatures(signatures) when is_list(signatures),
    do: signatures |> Enum.take(@item_limit) |> Enum.map(&decode_signature/1)

  defp decode_signature(%{label: label} = signature) when is_binary(label) do
    parameters =
      Enum.map(Map.get(signature, :parameters, []), fn label when is_binary(label) -> label end)

    %{
      label: label,
      parameters: parameters,
      doc: text(signature, :doc),
      active_parameter: active_parameter(Map.get(signature, :active_parameter), parameters)
    }
  end

  defp active_parameter(nil, _parameters), do: nil

  defp active_parameter(index, parameters)
       when is_integer(index) and index >= 0 and index < length(parameters),
       do: index

  defp result(responses) do
    case Enum.find(responses, &match?({:delegate, _request}, &1)) do
      nil ->
        %{
          mode: if(Enum.any?(responses, &(&1.mode == :override)), do: :override, else: :augment),
          candidates: Enum.flat_map(responses, & &1.candidates),
          incomplete?: Enum.any?(responses, & &1.incomplete?)
        }

      delegation ->
        delegation
    end
  end
end
