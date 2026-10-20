defmodule Expert.Search.Fuzzy do
  @moduledoc """
  In-memory fuzzy matcher for search entries.
  """

  import Record

  alias Expert.EngineApi
  alias Expert.Search.Fuzzy.Scorer
  alias Expert.Search.Indexer.Paths
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defstruct subject_to_values: %{},
            grouping_key_to_values: %{},
            preprocessed_subjects: %{},
            mapper: nil,
            filter_fn: nil,
            subject_converter: nil

  defrecordp :mapped,
    application: nil,
    grouping_key: nil,
    subject: nil,
    subtype: nil,
    type: nil,
    value: nil

  @type subject :: String.t()
  @type extracted_subject :: term()
  @type grouping_key :: term()
  @type value :: term()
  @type extracted_subject_grouping_key_value :: {extracted_subject(), grouping_key(), value()}
  @type mapper :: (term() -> extracted_subject_grouping_key_value())
  @type subject_converter :: (extracted_subject() -> subject())

  @opaque t :: %__MODULE__{
            subject_to_values: %{subject() => [value()]},
            grouping_key_to_values: %{Path.t() => [value()]},
            preprocessed_subjects: %{subject() => tuple()},
            mapper: mapper(),
            subject_converter: subject_converter()
          }

  @spec from_entries(Project.t(), [Entry.t()]) :: t()
  def from_entries(%Project{} = project, entries) do
    mapper = default_mapper()
    new(entries, mapper, &stringify/1, build_filter_fn(project), true)
  end

  @doc """
  Starts building an index from the definitions a replace writes, batch by
  batch, so it's ready when the store is. `finish/1` returns it.
  """
  @spec builder(Project.t()) :: pid()
  def builder(%Project{} = project) do
    filter = build_filter_fn(project)
    {:ok, builder} = Agent.start_link(fn -> {filter, default_mapper(), %{}, %{}, %{}} end)
    builder
  end

  @spec feed(pid(), [term()]) :: :ok
  def feed(builder, items) when is_list(items) do
    # Only the definitions are sent: a batch's other items, with their encoded
    # rows, would be copied to the builder for nothing.
    definitions = definition_entries(items, [])
    Agent.cast(builder, &collect(&1, definitions))
  end

  @spec finish(pid()) :: t()
  def finish(builder) do
    fuzzy = Agent.get(builder, &built/1, :infinity)
    Agent.stop(builder)
    fuzzy
  end

  @spec abandon(pid()) :: :ok
  def abandon(builder), do: Agent.stop(builder)

  defp collect({filter, mapper, subjects, groups, preprocessed}, definitions) do
    {subjects, groups, preprocessed} =
      Enum.reduce(definitions, {subjects, groups, preprocessed}, fn entry,
                                                                    {subjects, groups,
                                                                     preprocessed} ->
        mapped = mapper.(entry)

        if filter.(mapped) do
          subject = stringify(mapped)
          mapped(grouping_key: grouping_key, value: value) = mapped

          {Map.update(subjects, subject, [value], &[value | &1]),
           Map.update(groups, grouping_key, [value], &[value | &1]),
           Map.put_new_lazy(preprocessed, subject, fn -> Scorer.preprocess(subject) end)}
        else
          {subjects, groups, preprocessed}
        end
      end)

    {filter, mapper, subjects, groups, preprocessed}
  end

  # the order of a key's values doesn't matter to matching
  defp built({filter, mapper, subjects, groups, preprocessed}) do
    %__MODULE__{
      filter_fn: filter,
      grouping_key_to_values: groups,
      mapper: mapper,
      preprocessed_subjects: preprocessed,
      subject_converter: &stringify/1,
      subject_to_values: subjects
    }
  end

  defp definition_entries(
         [{:encoded, %Entry{subtype: :definition} = entry, _row} | items],
         entries
       ),
       do: definition_entries(items, [entry | entries])

  defp definition_entries([%Entry{subtype: :definition} = entry | items], entries),
    do: definition_entries(items, [entry | entries])

  defp definition_entries([_item | items], entries), do: definition_entries(items, entries)
  defp definition_entries([], entries), do: entries

  @spec from_backend(Project.t(), module()) :: {:ok, t()} | {:error, term()}
  def from_backend(%Project{} = project, backend) do
    mapper = default_mapper()

    case backend.definitions_for_fuzzy(project) do
      entries when is_list(entries) ->
        mapped_items = Enum.map(entries, mapper)
        {:ok, new(mapped_items, mapper, &stringify/1, build_filter_fn(project), false)}

      {:error, _} = error ->
        error
    end
  end

  @spec new(Enumerable.t(), mapper(), subject_converter(), function(), boolean()) :: t()
  def new(items, mapper, subject_converter, filter_fun, map_items?) do
    mapped_items =
      if map_items? do
        items
        |> Stream.map(mapper)
        |> Enum.filter(filter_fun)
      else
        Enum.filter(items, filter_fun)
      end

    extract_and_fix_subject = fn mapped() = mapped -> subject_converter.(mapped) end
    extract_value = fn mapped(value: value) -> value end

    subject_to_values = Enum.group_by(mapped_items, extract_and_fix_subject, extract_value)
    extract_grouping_key = fn mapped(grouping_key: grouping_key) -> grouping_key end
    grouping_key_to_values = Enum.group_by(mapped_items, extract_grouping_key, extract_value)

    preprocessed_subjects =
      subject_to_values
      |> Map.keys()
      |> Map.new(fn subject -> {subject, Scorer.preprocess(subject)} end)

    %__MODULE__{
      filter_fn: filter_fun,
      grouping_key_to_values: grouping_key_to_values,
      mapper: mapper,
      preprocessed_subjects: preprocessed_subjects,
      subject_converter: subject_converter,
      subject_to_values: subject_to_values
    }
  end

  @spec match(t(), String.t()) :: [Entry.entry_id()]
  def match(%__MODULE__{} = fuzzy, pattern) do
    fuzzy.subject_to_values
    |> Stream.map(fn {subject, ids} ->
      case score(fuzzy, subject, pattern) do
        {:ok, score} -> {score, ids}
        :error -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.flat_map(&elem(&1, 1))
  end

  @spec add(t(), term() | [term()]) :: t()
  def add(%__MODULE__{} = fuzzy, items) when is_list(items) do
    items
    |> definition_entries([])
    |> Enum.reduce(fuzzy, fn entry, fuzzy -> add(fuzzy, entry) end)
  end

  def add(%__MODULE__{} = fuzzy, item) do
    mapped_item = fuzzy.mapper.(item)

    if fuzzy.filter_fn.(mapped_item) do
      subject = fuzzy.subject_converter.(mapped_item)
      mapped(grouping_key: grouping_key, value: value) = mapped_item

      updated_grouping_key_to_values =
        Map.update(fuzzy.grouping_key_to_values, grouping_key, [value], fn old_ids ->
          [value | old_ids]
        end)

      updated_subject_to_values =
        Map.update(fuzzy.subject_to_values, subject, [value], fn old_ids -> [value | old_ids] end)

      updated_preprocessed_subjects =
        Map.put_new_lazy(fuzzy.preprocessed_subjects, subject, fn ->
          Scorer.preprocess(subject)
        end)

      %__MODULE__{
        fuzzy
        | grouping_key_to_values: updated_grouping_key_to_values,
          subject_to_values: updated_subject_to_values,
          preprocessed_subjects: updated_preprocessed_subjects
      }
    else
      fuzzy
    end
  end

  @spec has_grouping_key?(t(), grouping_key()) :: boolean()
  def has_grouping_key?(%__MODULE__{} = fuzzy, grouping_key) do
    Map.has_key?(fuzzy.grouping_key_to_values, grouping_key)
  end

  @spec has_subject?(t(), extracted_subject() | subject()) :: boolean()
  def has_subject?(%__MODULE__{} = fuzzy, subject) when is_binary(subject) do
    Map.has_key?(fuzzy.subject_to_values, subject)
  end

  def has_subject?(%__MODULE__{} = fuzzy, subject) do
    has_subject?(fuzzy, fuzzy.subject_converter.(subject))
  end

  @spec delete_grouping_key(t(), grouping_key()) :: t()
  def delete_grouping_key(%__MODULE__{} = fuzzy, grouping_key) do
    values = Map.get(fuzzy.grouping_key_to_values, grouping_key, [])
    fuzzy = drop_values(fuzzy, values)

    %__MODULE__{
      fuzzy
      | grouping_key_to_values: Map.delete(fuzzy.grouping_key_to_values, grouping_key)
    }
  end

  @spec drop_values(t(), [value()]) :: t()
  def drop_values(%__MODULE__{} = fuzzy, []), do: fuzzy

  def drop_values(%__MODULE__{} = fuzzy, values) do
    values_mapset = MapSet.new(values)

    reject_values = fn {subject, values} ->
      {subject, Enum.reject(values, &MapSet.member?(values_mapset, &1))}
    end

    empty_values? = fn
      {_, []} -> true
      {_, _} -> false
    end

    subject_to_values =
      fuzzy.subject_to_values
      |> Stream.map(reject_values)
      |> Stream.reject(empty_values?)
      |> Map.new()

    all_subjects =
      subject_to_values
      |> Map.keys()
      |> MapSet.new()

    grouping_key_to_values =
      fuzzy.grouping_key_to_values
      |> Stream.map(reject_values)
      |> Stream.reject(empty_values?)
      |> Map.new()

    preprocessed_subjects =
      fuzzy.preprocessed_subjects
      |> Stream.filter(fn {subject, _} -> MapSet.member?(all_subjects, subject) end)
      |> Map.new()

    %__MODULE__{
      fuzzy
      | subject_to_values: subject_to_values,
        grouping_key_to_values: grouping_key_to_values,
        preprocessed_subjects: preprocessed_subjects
    }
  end

  defp score(%__MODULE__{} = fuzzy, subject, pattern) do
    with {:ok, preprocessed} <- Map.fetch(fuzzy.preprocessed_subjects, subject),
         {true, score} <- Scorer.score(preprocessed, pattern) do
      {:ok, score}
    else
      _ -> :error
    end
  end

  defp stringify(mapped(type: {:function, _}, subject: subject)) do
    subject
    |> String.split(".")
    |> List.last()
    |> String.split("/")
    |> List.first()
  end

  defp stringify(mapped(type: :module, subject: module_name)),
    do: Forge.Formats.module(module_name)

  defp stringify(mapped(subject: string)) when is_binary(string), do: string
  defp stringify(mapped(subject: thing)), do: inspect(thing)
  defp stringify(thing) when is_binary(thing), do: thing

  defp stringify(atom) when is_atom(atom) do
    cond do
      function_exported?(atom, :__info__, 1) -> Forge.Formats.module(atom)
      function_exported?(atom, :module_info, 0) -> Forge.Formats.module(atom)
      true -> inspect(atom)
    end
  end

  defp stringify(thing), do: inspect(thing)

  defp default_mapper do
    fn %Entry{} = entry ->
      mapped(
        application: entry.application,
        grouping_key: entry.path,
        subject: entry.subject,
        subtype: entry.subtype,
        type: entry.type,
        value: entry.id
      )
    end
  end

  defp build_filter_fn(%Project{} = project) do
    deps_directories = deps_roots(project)

    fn
      mapped(subtype: :definition, grouping_key: path) ->
        not Enum.any?(deps_directories, &String.starts_with?(path, &1))

      _ ->
        false
    end
  end

  # The dependency and build roots the indexer leaves out of the sources, which
  # it has from the project's configuration rather than from walking it. The
  # engine isn't there to ask when the store starts, which leaves the usual
  # roots.
  defp deps_roots(%Project{} = project) do
    configuration = fn configured ->
      try do
        EngineApi.project_configuration(project, configured)
      rescue
        _no_engine -> {:error, :engine}
      end
    end

    %Paths{unlisted_sources: {_root, excluded}} = Paths.without_sources(project, configuration)
    excluded
  end
end
