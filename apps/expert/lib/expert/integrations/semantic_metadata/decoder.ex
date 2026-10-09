defmodule Expert.Integrations.SemanticMetadata.Decoder do
  @moduledoc false

  require Logger

  @attribute :elixir_semantic_metadata
  @version :elixir_semantic_metadata_v1
  @block_keys [:do, :else, :after, :rescue, :catch]
  @documentation_kinds [:function, :macro]

  def decode(attributes) when is_list(attributes) do
    attributes
    |> Keyword.get_values(@attribute)
    |> Enum.flat_map(&attribute_documents/1)
    |> Enum.flat_map(&decode_attribute/1)
  end

  def decode(_attributes), do: []

  defp attribute_documents(documents) when is_list(documents), do: documents
  defp attribute_documents(document), do: [document]

  defp decode_attribute({@version, document}) do
    case decode_document(document) do
      {:ok, decoded} ->
        [decoded]

      :error ->
        Logger.warning("Ignored invalid #{@version} metadata")
        []
    end
  end

  defp decode_attribute(_attribute), do: []

  defp decode_document(%{} = document) when not is_struct(document) do
    with true <- fields?(document, [:contexts, :scopes]),
         {:ok, scopes} <- scopes(document[:scopes]),
         {:ok, contexts} <- list(document[:contexts], &context/1),
         true <- contexts != [],
         true <- valid_references?(contexts, scopes),
         true <- unique_contexts?(contexts) do
      {:ok, %{kind: :dsl, contexts: contexts, scopes: scopes}}
    else
      _ -> :error
    end
  end

  defp decode_document(_document), do: :error

  defp context(%{argument: argument} = context) when not is_struct(context) do
    with true <- fields?(context, [:mfa, :argument, :scope]),
         {:ok, mfa} <- mfa(context[:mfa]),
         {:ok, argument} <- argument(argument),
         {:ok, scope} <- scope_id(context[:scope]) do
      {:ok, %{mfa: mfa, argument: argument, scope: scope}}
    else
      _ -> :error
    end
  end

  defp context(%{block: block} = context) when not is_struct(context) do
    with true <- fields?(context, [:mfa, :block, :scope]),
         {:ok, mfa} <- mfa(context[:mfa]),
         {:ok, block} <- block(block),
         {:ok, scope} <- scope_id(context[:scope]) do
      {:ok, %{mfa: mfa, block: block, scope: scope}}
    else
      _ -> :error
    end
  end

  defp context(_context), do: :error

  defp scopes(%{} = scopes) when not is_struct(scopes) do
    Enum.reduce_while(scopes, {:ok, %{}}, fn {id, scope}, {:ok, decoded} ->
      with {:ok, id} <- scope_id(id),
           {:ok, scope} <- scope(scope) do
        {:cont, {:ok, Map.put(decoded, id, scope)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp scopes(_scopes), do: :error

  defp scope(%{} = scope) when not is_struct(scope) do
    with true <- fields?(scope, [:entries], [:data]),
         {:ok, entries} <- list(scope[:entries], &entry/1),
         true <- unique_entries?(entries),
         {:ok, data} <- data(Map.get(scope, :data, [])) do
      {:ok, %{entries: entries, data: data}}
    else
      _ -> :error
    end
  end

  defp scope(_scope), do: :error

  defp data(data) when is_list(data) do
    if Keyword.keyword?(data) and safe_data?(data), do: {:ok, data}, else: :error
  end

  defp data(_data), do: :error

  defp safe_data?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: true

  defp safe_data?(value) when is_list(value), do: Enum.all?(value, &safe_data?/1)

  defp safe_data?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.all?(&safe_data?/1)
  end

  defp safe_data?(%{} = value) when not is_struct(value) do
    Enum.all?(value, fn {key, item} -> safe_data?(key) and safe_data?(item) end)
  end

  defp safe_data?(_value), do: false

  defp entry(%{kind: kind, mfa: entry_mfa} = entry)
       when is_atom(kind) and not is_struct(entry) do
    with true <- fields?(entry, [:kind, :mfa], [:doc]),
         {:ok, mfa} <- mfa(entry_mfa),
         {:ok, doc} <- optional_doc(entry[:doc]) do
      {:ok, put_doc(%{kind: kind, mfa: mfa}, doc)}
    else
      _ -> :error
    end
  end

  defp entry(%{kind: :keyword} = entry) when not is_struct(entry) do
    with true <- fields?(entry, [:kind, :name], [:doc, :value_scope]),
         {:ok, name} <- name(entry[:name]),
         {:ok, doc} <- optional_doc(entry[:doc]),
         {:ok, value_scope} <- optional_scope_id(entry[:value_scope]) do
      decoded = %{kind: :keyword, name: name}

      {:ok,
       decoded
       |> put_doc(doc)
       |> put_optional(:value_scope, value_scope)}
    else
      _ -> :error
    end
  end

  defp entry(%{kind: :literal} = entry) when not is_struct(entry) do
    with true <- fields?(entry, [:kind, :value], [:doc]),
         {:ok, value} <- literal(entry[:value]),
         {:ok, doc} <- optional_doc(entry[:doc]) do
      {:ok, put_doc(%{kind: :literal, value: value}, doc)}
    else
      _ -> :error
    end
  end

  defp entry(_entry), do: :error

  defp optional_scope_id(nil), do: {:ok, nil}
  defp optional_scope_id(scope), do: scope_id(scope)

  defp mfa({module, name, arity})
       when is_atom(module) and is_atom(name) and is_integer(arity) and arity >= 0 and
              arity <= 255 do
    {:ok, %{module: Atom.to_string(module), name: Atom.to_string(name), arity: arity}}
  end

  defp mfa(_mfa), do: :error

  defp argument(index) when is_integer(index) and index >= 0 and index <= 255,
    do: {:ok, index}

  defp argument(_index), do: :error
  defp block(key) when key in @block_keys, do: {:ok, key}
  defp block(_key), do: :error

  defp scope_id(id) when is_atom(id) or is_integer(id) or is_binary(id), do: {:ok, id}
  defp scope_id(_id), do: :error

  defp name(name) when is_atom(name), do: {:ok, Atom.to_string(name)}
  defp name(_name), do: :error

  defp literal(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: {:ok, value}

  defp literal(_value), do: :error

  defp optional_doc(nil), do: {:ok, nil}

  defp optional_doc(doc) when is_binary(doc), do: {:ok, doc}

  defp optional_doc({module, kind, name, arity})
       when is_atom(module) and kind in @documentation_kinds and is_atom(name) and
              is_integer(arity) and arity >= 0 and arity <= 255 do
    {:ok,
     %{
       module: Atom.to_string(module),
       kind: kind,
       name: Atom.to_string(name),
       arity: arity
     }}
  end

  defp optional_doc(_doc), do: :error

  defp valid_references?(contexts, scopes) do
    Enum.all?(contexts, &Map.has_key?(scopes, &1.scope)) and
      Enum.all?(scopes, fn {_id, scope} ->
        Enum.all?(scope.entries, fn
          %{kind: :keyword, value_scope: scope} -> Map.has_key?(scopes, scope)
          _entry -> true
        end)
      end)
  end

  defp unique_contexts?(contexts) do
    unique_by?(contexts, &{&1.mfa, context_position(&1)})
  end

  defp unique_entries?(entries) do
    unique_by?(entries, fn
      %{kind: kind, mfa: mfa} -> {kind, mfa}
      %{kind: :keyword, name: name} -> {:keyword, name}
      %{kind: :literal, value: value} -> {:literal, value}
    end)
  end

  defp unique_by?(values, key) do
    values
    |> Enum.map(key)
    |> then(&(length(&1) == length(Enum.uniq(&1))))
  end

  defp fields?(map, required, optional \\ []) do
    keys = Map.keys(map)

    Enum.all?(required, &Map.has_key?(map, &1)) and
      Enum.all?(keys, &(&1 in (required ++ optional)))
  end

  defp list(values, decoder) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, decoded} ->
      case decoder.(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp list(_values, _decoder), do: :error

  defp context_position(%{argument: argument}), do: {:argument, argument}
  defp context_position(%{block: block}), do: {:block, block}

  defp put_doc(map, nil), do: map
  defp put_doc(map, doc), do: Map.put(map, :doc, doc)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
