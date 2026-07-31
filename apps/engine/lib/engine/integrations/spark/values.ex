defmodule Engine.Integrations.Spark.Values do
  @moduledoc false

  alias Engine.ManagerApi
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Search.Indexer.Entry

  @callables [{:function, :public}, {:function, :delegate}, {:macro, :public}]

  def candidates(%Env{} = env, type), do: modules(env, type) ++ builtins(env, type)

  defp modules(env, %{kind: :behaviour, behaviour: target}) do
    env
    |> relation_entries(:behaviour, target)
    |> Enum.reject(& &1.metadata.payload.skip?)
    |> to_modules(env)
  end

  defp modules(env, %{kind: kind, behaviour: target})
       when kind in [:spark_behaviour, :spark_function_behaviour] do
    env
    |> relation_entries(:behaviour, target)
    |> Enum.reject(&(root(&1.metadata.payload.module) == root(target)))
    |> to_modules(env)
  end

  defp modules(env, %{kind: :spark, type: target}),
    do: env |> relation_entries(:type, target) |> to_modules(env)

  defp modules(_env, _type), do: []

  defp relation_entries(%Env{} = env, kind, target) do
    prefix = Entry.integration_subject_prefix("spark", kind, target)

    case ManagerApi.search_store_prefix(env.project, prefix,
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp to_modules(entries, env) do
    entries
    |> Enum.flat_map(fn
      %Entry{metadata: %{payload: %{module: module}}} -> module_candidate(module, env)
      _ -> []
    end)
    |> Enum.uniq_by(&{&1.name, &1.full_name})
  end

  defp module_candidate(module, env) when is_binary(module) do
    hint = hint(env)
    full_name = source_module(module)

    [full_name | aliases(module, env)]
    |> Enum.uniq()
    |> Enum.filter(&matches?(&1, hint))
    |> Enum.min_by(&String.length/1, fn -> nil end)
    |> case do
      nil ->
        []

      name ->
        [%Candidate.Module{name: insertion_name(name, hint), full_name: full_name, metadata: %{}}]
    end
  end

  defp module_candidate(_module, _env), do: []

  defp aliases("Elixir." <> module, %Env{} = env) do
    parts = String.split(module, ".")

    case Analysis.scopes_at(env.analysis, env.position) do
      [%Scope{} = scope | _] ->
        scope
        |> Scope.alias_map(env.position)
        |> Enum.flat_map(fn
          {_key, %Alias{module: target, as: as}} -> alias_name(parts, target, as)
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp aliases(_module, _env), do: []

  defp alias_name(parts, target, as) do
    target = Enum.map(target, &Atom.to_string/1)

    if Enum.take(parts, length(target)) == target,
      do: [Enum.join(Enum.map(as, &Atom.to_string/1) ++ Enum.drop(parts, length(target)), ".")],
      else: []
  end

  defp builtins(%Env{} = env, %{builtins: module}) when is_binary(module) do
    hint = hint(env)
    module = String.trim_leading(module, "Elixir.")

    if String.contains?(hint, ".") or not lowercase?(hint) do
      []
    else
      case ManagerApi.search_store_prefix(env.project, "#{module}.#{hint}", subtype: :definition) do
        {:ok, entries} ->
          entries
          |> Enum.flat_map(&callable(&1, module))
          |> Enum.uniq_by(&{&1.__struct__, &1.name, &1.arity})

        _ ->
          []
      end
    end
  end

  defp builtins(_env, _type), do: []

  defp callable(%Entry{type: type, subject: subject}, module)
       when type in @callables and is_binary(subject) do
    with rest when rest != subject <- String.replace_prefix(subject, module <> ".", ""),
         false <- String.contains?(rest, "."),
         [name, arity] <- String.split(rest, "/", parts: 2),
         false <- name in ["__info__", "module_info"],
         {arity, ""} <- Integer.parse(arity) do
      candidate = if type == {:macro, :public}, do: Candidate.Macro, else: Candidate.Function

      [
        struct(candidate,
          name: name,
          arity: arity,
          argument_names: if(arity == 0, do: [], else: Enum.map(1..arity, &"arg#{&1}")),
          origin: module,
          type: if(candidate == Candidate.Macro, do: :macro, else: :function),
          visibility: :public,
          metadata: %{}
        )
      ]
    else
      _ -> []
    end
  end

  defp callable(_entry, _module), do: []

  defp root(module),
    do: module |> String.trim_leading("Elixir.") |> String.split(".", parts: 2) |> hd()

  defp source_module("Elixir." <> module), do: module
  defp source_module(":" <> _ = module), do: module
  defp source_module(module), do: ":" <> module

  defp matches?(_module, ""), do: true

  defp matches?(module, hint) do
    module = String.downcase(module)
    hint = String.downcase(hint)

    String.starts_with?(module, hint) or
      String.starts_with?(List.last(String.split(module, ".")), hint)
  end

  defp insertion_name(module, hint) do
    module
    |> String.split(".")
    |> Enum.drop(hint |> String.graphemes() |> Enum.count(&(&1 == ".")))
    |> Enum.join(".")
  end

  defp lowercase?(""), do: true
  defp lowercase?(hint), do: String.first(hint) == String.downcase(String.first(hint))

  defp hint(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {kind, chars} when kind in [:alias, :local_or_var, :local_call] -> to_string(chars)
      {:alias, _base, chars} -> to_string(chars)
      _ -> ""
    end
  end
end
