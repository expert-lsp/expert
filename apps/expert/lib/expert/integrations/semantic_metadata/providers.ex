defmodule Expert.Integrations.SemanticMetadata.Providers do
  @moduledoc false

  alias Expert.EngineApi
  alias Expert.Search.Indexer.Analyzer
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  require Logger

  @callback_timeout 10_000
  @candidate_limit 500
  @kinds [
    :class,
    :color,
    :constant,
    :constructor,
    :enum,
    :enum_member,
    :event,
    :field,
    :file,
    :folder,
    :function,
    :interface,
    :keyword,
    :method,
    :module,
    :operator,
    :property,
    :reference,
    :snippet,
    :struct,
    :text,
    :type_parameter,
    :unit,
    :value,
    :variable
  ]

  def complete(scope, cursor_path, %Env{} = env) do
    scope
    |> invoke_all(:completion, cursor_path, env, completion_fields(env))
    |> Enum.map(&decode_completion/1)
    |> result()
  end

  def hover(scope, cursor_path, %Env{} = env, name, %Range{} = range) do
    fields = %{name: name, range: range_map(range)}

    scope
    |> invoke_all(:hover, cursor_path, env, fields)
    |> Enum.flat_map(&decode_hover/1)
  end

  def signature_help(scope, cursor_path, %Env{} = env, active_argument) do
    scope
    |> invoke_all(:signature_help, cursor_path, env, %{active_argument: active_argument})
    |> Enum.flat_map(&decode_signatures/1)
  end

  defp invoke_all(%{data: data} = scope, facet, cursor_path, env, fields) do
    providers =
      data
      |> Keyword.get_values(:expert)
      |> Enum.flat_map(&providers(&1, facet))

    with [_ | _] <- providers,
         {:ok, call_context} <- call_context(scope.call, scope.target, env) do
      request = Map.merge(request(scope, call_context, cursor_path, env), fields)
      Enum.map(providers, &call_provider(facet, &1, env, request))
    else
      _providers -> []
    end
  end

  defp providers(%{facets: %{} = facets}, facet) do
    case Map.get(facets, facet) do
      providers when is_list(providers) -> Enum.flat_map(providers, &provider/1)
      _providers -> []
    end
  end

  defp providers(_data, _facet), do: []

  defp provider({module, function, 1}) when is_atom(module) and is_atom(function),
    do: [{module, function}]

  defp provider(_provider), do: []

  defp call_provider(facet, {provider, function}, env, request) do
    started_at = System.monotonic_time()

    response = EngineApi.call_fresh(env.project, provider, function, [request], @callback_timeout)
    duration = System.monotonic_time() - started_at

    Logger.debug(
      "Provider #{facet} provider=#{inspect(provider)} " <>
        "duration_us=#{System.convert_time_unit(duration, :native, :microsecond)}"
    )

    {:ok, response}
  rescue
    error ->
      Logger.warning(
        "Provider #{facet} failed provider=#{inspect(provider)} " <>
          "error=#{Exception.message(error)}"
      )

      :error
  catch
    kind, reason when kind in [:exit, :throw] ->
      Logger.warning(
        "Provider #{facet} failed provider=#{inspect(provider)} " <>
          "kind=#{kind} reason=#{inspect(reason)}"
      )

      :error
  end

  defp call_context(call, target, %Env{} = env) do
    with {:ok, arguments} <- fragment_arguments(call, env) do
      {:ok,
       %{
         args: arguments,
         ast: call,
         target: target
       }}
    end
  end

  defp request(scope, call_context, cursor_path, %Env{} = env) do
    %{
      aliases: Analyzer.aliases_at(env.analysis, env.position),
      ancestors: cursor_path,
      call: call_context,
      language_id: env.document.language_id,
      module: present(env.position_module),
      path: env.document.path,
      position: %{line: env.position.line, character: env.position.character},
      semantic: %{scope: scope.scope, target: scope.target},
      source: Document.to_string(env.document),
      uri: env.document.uri
    }
  end

  defp completion_fields(%Env{} = env), do: %{context: cursor_context(env), hint: hint(env)}

  defp range_map(%Range{start: start, end: stop}) do
    %{
      start: %{line: start.line, character: start.character},
      end: %{line: stop.line, character: stop.character}
    }
  end

  defp present(""), do: nil
  defp present(value), do: value

  defp cursor_context(%Env{} = env) do
    if Env.in_context?(env, :string), do: :string, else: :code
  end

  defp fragment_arguments(call, %Env{} = env) do
    with [line: line, column: column] <- fragment_start(call),
         start = Position.new(env.document, line, column),
         fragment = Document.fragment(env.document, start, env.position),
         {:ok, parsed} <- Code.Fragment.container_cursor_to_quoted(fragment),
         {:ok, arguments} <- call_arguments(parsed) do
      {:ok, arguments}
    else
      _error -> :error
    end
  end

  defp fragment_start({:|>, _, [left, _call]}), do: Sourceror.get_start_position(left)
  defp fragment_start(call), do: Sourceror.get_start_position(call)

  defp call_arguments({{:., _, [_module, _name]}, _, arguments}) when is_list(arguments),
    do: {:ok, arguments}

  defp call_arguments({:|>, _, [left, call]}) do
    with {:ok, arguments} <- call_arguments(call) do
      {:ok, [left | arguments]}
    end
  end

  defp call_arguments({_name, _, arguments}) when is_list(arguments), do: {:ok, arguments}
  defp call_arguments(_call), do: :error

  defp decode_completion({:ok, response}), do: decode_response(response)
  defp decode_completion(:error), do: empty_response()

  defp decode_hover({:ok, markdown}) when is_binary(markdown) and markdown != "", do: [markdown]
  defp decode_hover(_response), do: []

  defp decode_signatures({:ok, signatures}) when is_list(signatures) do
    signatures
    |> Enum.take(@candidate_limit)
    |> Enum.flat_map(&decode_signature/1)
  end

  defp decode_signatures(_response), do: []

  defp decode_signature(%{label: label} = signature) when is_binary(label) do
    parameters = Map.get(signature, :parameters, [])

    if is_list(parameters) and Enum.all?(parameters, &is_binary/1) and
         optional_binary?(signature, :doc) do
      [%{label: label, parameters: parameters, doc: Map.get(signature, :doc)}]
    else
      []
    end
  end

  defp decode_signature(_signature), do: []

  defp decode_response(candidates) when is_list(candidates) do
    %{mode: :augment, candidates: decode_candidates(candidates), incomplete?: true}
  end

  defp decode_response(%{items: candidates} = response) when is_list(candidates) do
    mode = Map.get(response, :mode, :augment)
    incomplete? = Map.get(response, :incomplete?, true)

    if mode in [:augment, :override] and is_boolean(incomplete?) do
      %{mode: mode, candidates: decode_candidates(candidates), incomplete?: incomplete?}
    else
      empty_response()
    end
  end

  defp decode_response(_response), do: empty_response()

  defp decode_candidates(candidates) do
    candidates
    |> Enum.take(@candidate_limit)
    |> Enum.flat_map(&decode_candidate/1)
  end

  defp decode_candidate(%{label: label, kind: kind} = candidate)
       when is_binary(label) and kind in @kinds do
    with true <- optional_binary?(candidate, :insert_text),
         true <- optional_binary?(candidate, :filter_text),
         true <- optional_binary?(candidate, :detail),
         true <- optional_binary?(candidate, :documentation),
         true <- optional_binary?(candidate, :snippet),
         true <- insertion?(candidate) do
      [
        {%Candidate.Generic{
           label: label,
           filter_text: Map.get(candidate, :filter_text, label),
           insert_text: Map.get(candidate, :insert_text),
           detail: Map.get(candidate, :detail),
           documentation: Map.get(candidate, :documentation),
           priority: :contextual,
           kind: kind,
           snippet: Map.get(candidate, :snippet)
         }, []}
      ]
    else
      false -> []
    end
  end

  defp decode_candidate(_candidate), do: []

  defp optional_binary?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> is_binary(value)
    end
  end

  defp insertion?(candidate) do
    not (Map.has_key?(candidate, :insert_text) and Map.has_key?(candidate, :snippet))
  end

  defp empty_response do
    %{mode: :augment, candidates: [], incomplete?: false}
  end

  defp hint(%Env{} = env) do
    if Env.in_context?(env, :string) do
      trailing_hint(env.prefix)
    else
      case Code.Fragment.cursor_context(env.prefix) do
        {:alias, chars} -> to_string(chars)
        {:alias, _base, chars} -> to_string(chars)
        {:local_or_var, chars} -> to_string(chars)
        {:local_call, chars} -> to_string(chars)
        {:unquoted_atom, chars} -> to_string(chars)
        {:dot, _base, chars} -> to_string(chars)
        _context -> trailing_hint(env.prefix)
      end
    end
  end

  defp trailing_hint(prefix) do
    case Regex.run(~r/[[:alnum:]_!?\.\/:\-]+$/u, prefix) do
      [hint] -> hint
      _ -> ""
    end
  end

  defp result(responses) do
    result =
      Enum.reduce(
        responses,
        %{mode: :augment, candidates: [], incomplete?: false},
        fn response, acc ->
          %{
            mode: merge_mode(acc.mode, response.mode),
            candidates: acc.candidates ++ response.candidates,
            incomplete?: acc.incomplete? or response.incomplete?
          }
        end
      )

    candidates =
      Enum.uniq_by(result.candidates, fn {candidate, []} ->
        {candidate.label, candidate.kind}
      end)

    case {result.mode, candidates} do
      {:augment, []} -> :ignore
      {mode, candidates} -> {mode, candidates, result.incomplete?, []}
    end
  end

  defp merge_mode(:override, _mode), do: :override
  defp merge_mode(_mode, :override), do: :override
  defp merge_mode(_left, _right), do: :augment
end
