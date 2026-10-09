defmodule Expert.Integrations.Spark.Indexer do
  @moduledoc """
  Converts static `spark_opts` documentation metadata to Elixir semantic metadata.
  """

  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Decoder
  alias Forge.Search.Indexer.Entry

  @provider "semantic"
  @version :elixir_semantic_metadata_v1

  @impl Expert.Integrations
  def index(_project, binary, metadata, source_path) do
    module = Map.fetch!(metadata, :module)

    case fetch_docs(binary) do
      {:ok, {:docs_v1, _, _, _, _, _, entries}} ->
        Enum.flat_map(entries, &function_entries(&1, module, source_path))

      _error ->
        []
    end
  end

  defp function_entries({{kind, name, arity}, _, _, _, metadata}, module, source_path)
       when kind in [:function, :macro] do
    defaults = Map.get(metadata, :defaults, 0)

    for {argument_index, schema} <- Map.get(metadata, :spark_opts, []),
        is_integer(argument_index) and argument_index >= 0,
        callable_arity <- (arity - defaults)..arity,
        argument_index < callable_arity,
        document <- document(module, name, callable_arity, argument_index, schema) do
      key = Enum.join([module, name, callable_arity, argument_index], "/")
      Entry.integration(source_path, @provider, :dsl, key, document)
    end
  end

  defp function_entries(_entry, _module, _source_path), do: []

  defp document(module, name, arity, argument_index, schema) do
    {root, scopes, _next_id} = scope(normalize_schema(schema), 0)

    payload = %{
      contexts: [
        %{
          mfa: {module, name, arity},
          argument: argument_index,
          scope: root
        }
      ],
      scopes: scopes
    }

    Decoder.decode(elixir_semantic_metadata: [{@version, payload}])
  end

  defp scope(options, id) do
    {entries, scopes, next_id} =
      Enum.reduce(options, {[], %{}, id + 1}, fn option, {entries, scopes, next_id} ->
        {entry, child_scopes, next_id} = entry(option, next_id)
        {[entry | entries], Map.merge(scopes, child_scopes), next_id}
      end)

    scope = %{entries: Enum.reverse(entries), data: []}
    {id, Map.put(scopes, id, scope), next_id}
  end

  defp entry(%{kind: :keyword} = option, next_id) do
    children = option.options ++ option.values

    {value, scopes, next_id} =
      case children do
        [] ->
          {nil, %{}, next_id}

        children ->
          {child_id, scopes, next_id} = scope(children, next_id)
          {child_id, scopes, next_id}
      end

    entry =
      %{kind: :keyword, name: option.name}
      |> put_optional(:doc, option.documentation)
      |> put_optional(:value_scope, value)

    {entry, scopes, next_id}
  end

  defp entry(%{kind: :literal, value: value}, next_id) do
    {%{kind: :literal, value: value}, %{}, next_id}
  end

  defp fetch_docs(binary) do
    case :beam_lib.chunks(binary, [~c"Docs"]) do
      {:ok, {_module, [{~c"Docs", docs}]}} -> {:ok, :erlang.binary_to_term(docs)}
      _error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp normalize_schema(schema) when is_list(schema) do
    Enum.flat_map(schema, fn
      {name, config} when is_atom(name) and (is_list(config) or is_map(config)) ->
        if config_get(config, :private?, false) do
          []
        else
          [
            %{
              kind: :keyword,
              name: name,
              documentation: text(config_get(config, :doc)),
              values: option_values(config_get(config, :type)),
              options: nested_options(config_get(config, :type))
            }
          ]
        end

      _option ->
        []
    end)
  end

  defp normalize_schema(_schema), do: []

  defp option_values(:boolean), do: Enum.map([true, false], &literal/1)

  defp option_values({kind, values}) when kind in [:one_of, :in] do
    values
    |> Enum.to_list()
    |> Enum.flat_map(fn value -> if valid_literal?(value), do: [literal(value)], else: [] end)
  end

  defp option_values({:literal, value}) do
    if valid_literal?(value), do: [literal(value)], else: []
  end

  defp option_values({:or, types}), do: types |> Enum.flat_map(&option_values/1) |> Enum.uniq()
  defp option_values(_type), do: []

  defp nested_options({kind, schema}) when kind in [:keyword_list, :non_empty_keyword_list],
    do: normalize_schema(schema)

  defp nested_options(_type), do: []

  defp literal(value), do: %{kind: :literal, value: value, options: [], values: []}

  defp valid_literal?(value),
    do:
      is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or is_binary(value)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp config_get(config, key, default \\ nil)

  defp config_get(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_get(config, key, default) when is_map(config), do: Map.get(config, key, default)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
