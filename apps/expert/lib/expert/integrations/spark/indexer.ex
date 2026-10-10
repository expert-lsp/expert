defmodule Expert.Integrations.Spark.Indexer do
  @moduledoc false

  @behaviour Expert.Integrations

  alias Expert.Integrations.SemanticMetadata.Indexer
  alias Expert.Search.Indexer.BeamFile

  @impl Expert.Integrations
  def index(_project, beam, _exports, metadata, source_path) do
    attributes = Map.get(metadata, "attributes", [])

    with false <- List.keymember?(attributes, "elixir_semantic_metadata", 0),
         {:ok, {:docs_v1, _anno, _language, _format, _module_doc, _metadata, docs}} <-
           spark_docs(beam) do
      module = metadata |> Map.fetch!("module") |> String.to_atom()
      Enum.flat_map(docs, &entries(&1, module, source_path))
    else
      _ -> []
    end
  end

  defp entries({{kind, name, arity}, _anno, _signature, _doc, metadata}, module, source_path)
       when kind in [:function, :macro] do
    defaults = Map.get(metadata, :defaults, 0)

    for {index, schema} when is_integer(index) and index >= 0 <-
          Map.get(metadata, :spark_opts, []),
        {root, scopes} = scope(schema, %{}),
        callable_arity <- (arity - defaults)..arity//1,
        index < callable_arity,
        document = %{
          contexts: [%{mfa: {module, name, callable_arity}, argument: index, scope: root}],
          scopes: scopes
        },
        key = Enum.join([module, name, callable_arity, index], "/"),
        do: Indexer.entry(source_path, key, document)
  end

  defp entries(_doc, _module, _source_path), do: []

  defp scope(schema, scopes, values \\ []) do
    id = map_size(scopes)
    {entries, scopes} = Enum.flat_map_reduce(schema, Map.put(scopes, id, nil), &option/2)
    {id, Map.put(scopes, id, %{entries: entries ++ values})}
  end

  defp option({name, config}, scopes) when is_atom(name) and is_list(config) do
    if Keyword.get(config, :private?, false) do
      {[], scopes}
    else
      entry =
        case Keyword.get(config, :doc) do
          doc when is_binary(doc) -> %{kind: :keyword, name: name, doc: doc}
          _doc -> %{kind: :keyword, name: name}
        end

      case value_scope(Keyword.get(config, :type), scopes) do
        {nil, scopes} -> {[entry], scopes}
        {id, scopes} -> {[Map.put(entry, :value_scope, id)], scopes}
      end
    end
  end

  defp option(_option, scopes), do: {[], scopes}

  defp value_scope(type, scopes) do
    literals = for value <- literals(type), uniq: true, do: %{kind: :literal, value: value}

    case {nested_schema(type), literals} do
      {[], []} -> {nil, scopes}
      {schema, literals} -> scope(schema, scopes, literals)
    end
  end

  defp literals(:boolean), do: [true, false]

  defp literals({kind, values}) when kind in [:one_of, :in],
    do: for(value <- values, literal?(value), do: value)

  defp literals({:literal, value}), do: if(literal?(value), do: [value], else: [])
  defp literals({:or, types}), do: Enum.flat_map(types, &literals/1)
  defp literals(_type), do: []

  defp nested_schema({kind, schema}) when kind in [:keyword_list, :non_empty_keyword_list],
    do: schema

  defp nested_schema(_type), do: []

  defp literal?(value), do: is_atom(value) or is_number(value) or is_binary(value)

  # Decoding docs creates an atom for every name in them, so only docs that
  # mention spark_opts are decoded.
  defp spark_docs(beam) do
    with {:ok, chunk} <- BeamFile.chunk(beam, "Docs"),
         docs = uncompressed(chunk),
         true <- String.contains?(docs, "spark_opts") do
      {:ok, :erlang.binary_to_term(docs)}
    else
      _ -> :error
    end
  end

  defp uncompressed(<<131, 80, _size::32, compressed::binary>>),
    do: <<131, :zlib.uncompress(compressed)::binary>>

  defp uncompressed(term), do: term
end
