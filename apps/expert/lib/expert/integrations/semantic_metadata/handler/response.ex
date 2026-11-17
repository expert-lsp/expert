defmodule Expert.Integrations.SemanticMetadata.Handler.Response do
  @moduledoc false

  alias Expert.Integrations.SemanticMetadata.Completion.Result
  alias Expert.Integrations.SemanticMetadata.Handler.Positions
  alias Forge.Completion.Candidate
  alias Forge.Document
  alias Forge.Document.Location

  @item_limit 500
  @kinds Candidate.Generic.kinds()

  def completion(items, document, cursor) when is_list(items),
    do: %Result{mode: :augment, candidates: items(items, document, cursor), incomplete?: true}

  def completion(%{delegate: %{source: source}}, _document, _cursor) when is_binary(source),
    do: %Result{mode: :delegate, delegate: %{source: source}}

  def completion(%{items: items} = response, document, cursor) do
    %Result{
      mode: completion_mode(Map.get(response, :mode, :augment)),
      candidates: items(items, document, cursor),
      incomplete?: boolean(Map.get(response, :incomplete?, true))
    }
  end

  def combine_completions(results) do
    case Enum.find(results, &match?(%Result{mode: :delegate}, &1)) do
      nil ->
        %Result{
          mode: if(Enum.any?(results, &(&1.mode == :override)), do: :override, else: :augment),
          candidates: Enum.flat_map(results, & &1.candidates),
          incomplete?: Enum.any?(results, & &1.incomplete?)
        }

      delegation ->
        delegation
    end
  end

  def hover(nil, _document, _range), do: []
  def hover("", _document, _range), do: []
  def hover(markdown, _document, range) when is_binary(markdown), do: [{markdown, range}]

  def hover(%{contents: markdown, range: range}, document, _range) when is_binary(markdown),
    do: [{markdown, to_range(document, range)}]

  def locations(locations) when is_list(locations) do
    locations
    |> Enum.take(@item_limit)
    |> Enum.map(fn %{path: path, range: range} when is_binary(path) ->
      uri = Document.Path.ensure_uri(path)
      {:ok, document} = Document.Store.open_temporary(uri)
      Location.new(to_range(document, range), uri)
    end)
  end

  def resolution(nil, _document, _identifier_range), do: nil

  def resolution(%{delegate: %{source: source}}, _document, _identifier_range)
      when is_binary(source),
      do: {:delegate, %{source: source}}

  def resolution(%{entity: entity} = response, document, identifier_range) do
    range =
      case response do
        %{range: range} -> to_range(document, range)
        %{} -> identifier_range
      end

    {:entity, entity(entity), range}
  end

  def signatures(signatures) when is_list(signatures),
    do: signatures |> Enum.take(@item_limit) |> Enum.map(&signature/1)

  defp items(items, document, cursor) when is_list(items),
    do: items |> Enum.take(@item_limit) |> Enum.map(&item(&1, document, cursor))

  defp item(%{insert_text: _text, snippet: _snippet}, _document, _cursor),
    do: raise(ArgumentError, "an item has both :insert_text and :snippet")

  defp item(%{label: label, kind: kind} = item, document, cursor)
       when is_binary(label) and kind in @kinds do
    {:ok, range} = Positions.completion_range(document, cursor, Map.get(item, :range))

    %Candidate.Generic{
      label: label,
      kind: kind,
      range: range,
      filter_text: text(item, :filter_text) || label,
      insert_text: text(item, :insert_text),
      snippet: text(item, :snippet),
      detail: text(item, :detail),
      documentation: text(item, :documentation)
    }
  end

  defp completion_mode(mode) when mode in [:augment, :override], do: mode

  defp boolean(value) when is_boolean(value), do: value

  defp entity(%{kind: kind, module: module} = entity)
       when kind in [:module, :struct] and is_atom(module) and map_size(entity) == 2,
       do: entity

  defp entity(%{kind: kind, module: module, name: name, arity: arity} = entity)
       when kind in [:function, :macro, :type] and is_atom(module) and is_atom(name) and
              is_integer(arity) and arity >= 0 and map_size(entity) == 4,
       do: entity

  defp signature(%{label: label} = signature) when is_binary(label) do
    parameters =
      Enum.map(Map.get(signature, :parameters, []), fn parameter when is_binary(parameter) ->
        parameter
      end)

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

  defp text(map, key) do
    case Map.get(map, key) do
      nil -> nil
      text when is_binary(text) -> text
    end
  end

  defp to_range(document, range) do
    {:ok, range} = Positions.to_range(document, range)
    range
  end
end
