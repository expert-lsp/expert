defmodule ExpertEcto.Metadata do
  @moduledoc false

  @query_expressions [
    :where,
    :or_where,
    :select,
    :select_merge,
    :distinct,
    :order_by,
    :group_by,
    :having,
    :or_having,
    :limit,
    :offset,
    :lock,
    :preload,
    :update
  ]

  @joins [
    :join,
    :inner_join,
    :cross_join,
    :cross_lateral_join,
    :left_join,
    :right_join,
    :full_join,
    :inner_lateral_join,
    :left_lateral_join
  ]

  @additional_query_expressions [:prepend_order_by, :with_ties]
  @update_operations [:set, :inc, :push, :pull]

  @query_api [
    {:==, 2},
    {:!=, 2},
    {:<=, 2},
    {:>=, 2},
    {:<, 2},
    {:>, 2},
    {:+, 2},
    {:-, 2},
    {:*, 2},
    {:/, 2},
    {:and, 2},
    {:or, 2},
    {:not, 1},
    {:in, 2},
    {:exists, 1},
    {:any, 1},
    {:all, 1},
    {:like, 2},
    {:ilike, 2},
    {:is_nil, 1},
    {:count, 0},
    {:count, 1},
    {:count, 2},
    {:coalesce, 2},
    {:filter, 2},
    {:avg, 1},
    {:sum, 1},
    {:min, 1},
    {:max, 1},
    {:datetime_add, 3},
    {:date_add, 3},
    {:from_now, 2},
    {:ago, 2},
    {:fragment, 1},
    {:identifier, 1},
    {:constant, 1},
    {:splice, 1},
    {:values, 2},
    {:field, 2},
    {:struct, 2},
    {:map, 2},
    {:merge, 2},
    {:json_extract_path, 2},
    {:type, 2},
    {:as, 1},
    {:parent_as, 1},
    {:selected_as, 1},
    {:selected_as, 2}
  ]

  @window_api [
    {:count, 0},
    {:count, 1},
    {:avg, 1},
    {:sum, 1},
    {:min, 1},
    {:max, 1},
    {:over, 2},
    {:row_number, 0},
    {:rank, 0},
    {:dense_rank, 0},
    {:percent_rank, 0},
    {:cume_dist, 0},
    {:ntile, 1},
    {:first_value, 1},
    {:last_value, 1},
    {:filter, 2},
    {:nth_value, 2},
    {:lag, 1},
    {:lag, 2},
    {:lag, 3},
    {:lead, 1},
    {:lead, 2},
    {:lead, 3}
  ]

  @types [
    string: "`String.t()`, UTF-8 encoded",
    boolean: "`boolean()`",
    integer: "`integer()`",
    float: "`float()`",
    decimal: "`Decimal`",
    id: "`integer()`",
    date: "`Date`",
    time: "`Time`",
    time_usec: "`Time`",
    naive_datetime: "`NaiveDateTime`",
    naive_datetime_usec: "`NaiveDateTime`",
    utc_datetime: "`DateTime`",
    utc_datetime_usec: "`DateTime`",
    map: "`map()`",
    binary_id: "`binary()`",
    binary: "`binary()`"
  ]

  @schema_options [
    field: [
      default: :empty,
      source: :empty,
      autogenerate: :empty,
      read_after_writes: :booleans,
      virtual: :booleans,
      primary_key: :booleans,
      load_in_query: :booleans
    ],
    belongs_to: [
      foreign_key: :empty,
      references: :empty,
      define_field: :booleans,
      type: :field_types,
      on_replace: :on_replace,
      defaults: :empty,
      primary_key: :booleans,
      source: :empty,
      where: :empty
    ],
    has_one: [
      foreign_key: :empty,
      references: :empty,
      through: :empty,
      on_delete: :on_delete,
      on_replace: :on_replace,
      defaults: :empty,
      where: :empty
    ],
    has_many: [
      foreign_key: :empty,
      references: :empty,
      through: :empty,
      on_delete: :on_delete,
      on_replace: :on_replace,
      defaults: :empty,
      where: :empty
    ],
    many_to_many: [
      join_through: :empty,
      join_keys: :empty,
      on_delete: :many_to_many_on_delete,
      on_replace: :many_to_many_on_replace,
      defaults: :empty,
      join_defaults: :empty,
      unique: :booleans,
      where: :empty,
      join_where: :empty
    ],
    embeds_one: [
      on_replace: :embeds_one_on_replace,
      source: :empty,
      load_in_query: :booleans,
      defaults_to_struct: :booleans
    ],
    embeds_many: [
      on_replace: :many_to_many_on_replace,
      source: :empty,
      load_in_query: :booleans
    ]
  ]

  @associations [:belongs_to, :has_one, :has_many, :many_to_many, :embeds_one, :embeds_many]

  def joins, do: @joins

  def document do
    completion = %{completion: [{ExpertEcto, :complete, 1}]}
    data = [expert: %{facets: completion}]

    schema_option_scopes =
      Map.new(@schema_options, fn {macro, options} ->
        entries =
          for {name, value_scope} <- options,
              do: keyword(name, {Ecto.Schema, :macro, macro, 3}, value_scope)

        {:"#{macro}_options", %{entries: entries}}
      end)

    scopes =
      schema_option_scopes
      |> Map.merge(%{
        query_sources: %{entries: [], data: data},
        field_types: %{entries: type_literals(), data: data},
        column_types: %{entries: type_literals()},
        schemas: %{
          entries: [],
          data: [expert: %{facets: Map.put(completion, :resolve, [{ExpertEcto, :resolve, 1}])}]
        },
        booleans: %{entries: literals([true, false])},
        empty: %{entries: []},
        on_replace: %{entries: literals([:raise, :mark_as_invalid, :nilify, :update, :delete])},
        many_to_many_on_replace: %{entries: literals([:raise, :mark_as_invalid, :delete])},
        embeds_one_on_replace: %{entries: literals([:raise, :mark_as_invalid, :update, :delete])},
        on_delete: %{entries: literals([:nothing, :nilify_all, :delete_all])},
        many_to_many_on_delete: %{entries: literals([:nothing, :delete_all])}
      })
      |> Map.merge(query_scopes(data))

    %{contexts: contexts() ++ schema_contexts(), scopes: scopes}
  end

  defp type_literals do
    for {type, loads_as} <- @types,
        do: %{kind: :literal, value: type, doc: "Loads as #{loads_as}."}
  end

  defp literals(values), do: Enum.map(values, &literal/1)

  defp schema_contexts do
    association_contexts =
      for macro <- @associations,
          context <- [
            context({Ecto.Schema, macro, 2}, 1, :schemas),
            context({Ecto.Schema, macro, 3}, 1, :schemas),
            context({Ecto.Schema, macro, 3}, 2, :"#{macro}_options")
          ],
          do: context

    embed_block_contexts =
      for macro <- [:embeds_one, :embeds_many],
          context <- [
            context({Ecto.Schema, macro, 4}, 1, :schemas),
            context({Ecto.Schema, macro, 4}, 2, :"#{macro}_options")
          ],
          do: context

    [
      context({Ecto.Schema, :field, 2}, 1, :field_types),
      context({Ecto.Schema, :field, 3}, 1, :field_types),
      context({Ecto.Schema, :field, 3}, 2, :field_options),
      context({Ecto.Migration, :add, 2}, 1, :column_types),
      context({Ecto.Migration, :add, 3}, 1, :column_types)
      | association_contexts ++ embed_block_contexts
    ]
  end

  defp query_scopes(data) do
    %{
      query_options: %{entries: query_options()},
      join_options: %{entries: join_options()},
      cte_options: %{entries: cte_options()},
      update_operations: %{entries: update_operations()},
      cte_operations: %{entries: literals([:all, :update_all, :delete_all])},
      expressions: %{entries: expression_callables(), data: data}
    }
  end

  defp contexts do
    query_contexts =
      Enum.flat_map(@query_expressions ++ @additional_query_expressions, fn name ->
        scope = query_expression_scope(name)

        [
          context({Ecto.Query, name, 2}, 1, scope),
          context({Ecto.Query, name, 3}, 2, scope)
        ]
      end)

    [
      context({Ecto.Query, :from, 1}, 0, :query_sources),
      context({Ecto.Query, :from, 2}, 0, :query_sources),
      context({Ecto.Query, :from, 2}, 1, :query_options),
      context({Ecto.Query, :join, 3}, 2, :query_sources),
      context({Ecto.Query, :join, 4}, 3, :query_sources),
      context({Ecto.Query, :join, 5}, 3, :query_sources),
      context({Ecto.Query, :dynamic, 1}, 0, :expressions),
      context({Ecto.Query, :dynamic, 2}, 1, :expressions),
      context({Ecto.Query, :join, 5}, 4, :join_options),
      context({Ecto.Query, :with_cte, 3}, 2, :cte_options),
      context({Ecto.Query, :windows, 2}, 1, :expressions),
      context({Ecto.Query, :windows, 3}, 2, :expressions)
      | query_contexts
    ]
  end

  defp context(mfa, index, scope) do
    %{mfa: mfa, argument: index, scope: scope}
  end

  defp query_options do
    expression_options =
      Enum.map(@query_expressions, &keyword(&1, query_doc(&1, 3), query_expression_scope(&1)))

    joins = Enum.map(@joins, &keyword(&1, query_doc(:join, 5), :query_sources))

    expression_options ++
      joins ++
      [
        keyword(:union, query_doc(:union, 2)),
        keyword(:union_all, query_doc(:union_all, 2)),
        keyword(:except, query_doc(:except, 2)),
        keyword(:except_all, query_doc(:except_all, 2)),
        keyword(:intersect, query_doc(:intersect, 2)),
        keyword(:intersect_all, query_doc(:intersect_all, 2)),
        keyword(:windows, query_doc(:windows, 3), :expressions),
        keyword(:with_ties, query_doc(:with_ties, 3), :booleans),
        keyword(:on, query_doc(:join, 5), :expressions),
        keyword(:as, query_doc(:from, 2)),
        keyword(:prefix, query_doc(:from, 2)),
        keyword(:hints, query_doc(:from, 2))
      ]
  end

  defp join_options do
    [
      keyword(:on, query_doc(:join, 5), :expressions),
      keyword(:as, query_doc(:join, 5)),
      keyword(:prefix, query_doc(:join, 5)),
      keyword(:hints, query_doc(:join, 5))
    ]
  end

  defp cte_options do
    [
      keyword(:as, query_doc(:with_cte, 3), :expressions),
      keyword(:materialized, query_doc(:with_cte, 3), :booleans),
      keyword(:operation, query_doc(:with_cte, 3), :cte_operations)
    ]
  end

  defp update_operations do
    Enum.map(@update_operations, &keyword(&1, query_doc(:update, 3), :expressions))
  end

  defp query_expression_scope(:update), do: :update_operations
  defp query_expression_scope(:preload), do: :empty
  defp query_expression_scope(_name), do: :expressions

  defp expression_callables do
    Enum.map(@query_api, &callable(Ecto.Query.API, &1)) ++
      Enum.map(@window_api, &callable(Ecto.Query.WindowAPI, &1))
  end

  defp callable(module, {name, arity}) do
    %{
      kind: :function,
      mfa: {module, name, arity},
      doc: {module, :function, name, documented_arity(module, name, arity)}
    }
  end

  defp documented_arity(Ecto.Query.WindowAPI, name, arity)
       when name in [:lag, :lead] and arity < 3,
       do: 3

  defp documented_arity(_module, _name, arity), do: arity

  defp keyword(name, doc, value_scope \\ :empty),
    do: %{kind: :keyword, name: name, doc: doc, value_scope: value_scope}

  defp literal(value), do: %{kind: :literal, value: value}

  defp query_doc(name, arity), do: {Ecto.Query, :macro, name, arity}
end
