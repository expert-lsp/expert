defmodule Engine.Search.Fuzzy do
  @moduledoc """
  A backend for fuzzy matching

  This is a storage module that allows you to map keys to multiple values in two ways.

  Values are grouped by their `subject`, which is a string that enables fuzzy matching. They can also be grouped
  by a `grouping key` that allows for grouping by an arbitrary value.

  For both cases, multiple values can exist under the same key, and when searching, all values under the key are
  returned.
  """

  import Record

  alias Engine.Search.Fuzzy.Scorer
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
  @type mapper :: (term -> extracted_subject_grouping_key_value)
  @type subject_converter :: (extracted_subject() -> subject())

  @opaque t :: %__MODULE__{
            subject_to_values: %{subject() => [value()]},
            grouping_key_to_values: %{Path.t() => [value()]},
            preprocessed_subjects: %{subject() => tuple()},
            mapper: mapper(),
            subject_converter: subject_converter()
          }

  @spec from_entries([Entry.t()]) :: t
  def from_entries(entries) do
    mapper = default_mapper()

    new(entries, mapper, &stringify/1, true)
  end

  @doc """
  Creates a new fuzzy matcher.

  Items in the enumerable first argument will have the mapper function applied to them.
  For each tuple returned, the first element will then have the subject converter applied.
  This will produce a subject, which is what the `match/2` function uses for fuzzy matching.
  """
  @spec new(Enumerable.t(), mapper(), subject_converter(), boolean()) :: t
  def new(items, mapper, subject_converter, map_items?) do
    filter_fun = build_filter_fn()

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

  @doc """
  Applies fuzzy matching to the pattern.

  Values that match will be aggregated and returned sorted
  in descending order of the match relevance. Items at the beginning of the list
  will have a higher score than items at the end.
  """
  @spec match(t(), String.t()) :: [Entry.entry_id()]
  def match(%__MODULE__{} = fuzzy, pattern) do
    fuzzy.subject_to_values
    |> Stream.map(fn {subject, ids} ->
      case score(fuzzy, subject, pattern) do
        {:ok, score} ->
          {score, ids}

        :error ->
          nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.flat_map(&elem(&1, 1))
  end

  @doc """
  Adds a single item or a list of items to the fuzzy instance.
  """
  @spec add(t, term | [term]) :: t
  def add(%__MODULE__{} = fuzzy, items) when is_list(items) do
    Enum.reduce(items, fuzzy, fn entry, fuzzy ->
      add(fuzzy, entry)
    end)
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
        Map.update(fuzzy.subject_to_values, subject, [value], fn old_ids ->
          [value | old_ids]
        end)

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

  @doc """
  Returns true if the fuzzy instance has the specified grouping_key
  """
  @spec has_grouping_key?(t, grouping_key()) :: boolean
  def has_grouping_key?(%__MODULE__{} = fuzzy, grouping_key) do
    Map.has_key?(fuzzy.grouping_key_to_values, grouping_key)
  end

  @doc """
  Returns true if the fuzzy instance has the specified subject.

  If the subject is a string, the conversion function passed into the
  constructor will be applied to the `subject` parameter.
  """
  @spec has_subject?(t, extracted_subject() | subject()) :: boolean
  def has_subject?(%__MODULE__{} = fuzzy, subject) when is_binary(subject) do
    Map.has_key?(fuzzy.subject_to_values, subject)
  end

  def has_subject?(%__MODULE__{} = fuzzy, subject) do
    has_subject?(fuzzy, fuzzy.subject_converter.(subject))
  end

  @spec drop_values(t, [value()]) :: t
  def drop_values(%__MODULE__{} = fuzzy, []) do
    # a little optimization; drop_values is pretty expensive, and it's used in
    # delete_grouping_key. If there is nothing to delete, we should just return the fuzzy
    # unmodified.
    fuzzy
  end

  @doc """
  Removes all the given values from the data structure.

  If dropping the values results in a subject or grouping key having no entries in the data structure,
  the subject or grouping key is also removed.
  """
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
      |> Stream.filter(fn {subject, _} ->
        MapSet.member?(all_subjects, subject)
      end)
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
      _ ->
        :error
    end
  end

  defp stringify(mapped(type: {:function, _}, subject: subject)) do
    subject
    |> String.split(".")
    |> List.last()
    |> String.split("/")
    |> List.first()
  end

  defp stringify(mapped(type: :module, subject: module_name)) do
    Forge.Formats.module(module_name)
  end

  defp stringify(mapped(subject: string)) when is_binary(string) do
    string
  end

  defp stringify(mapped(subject: thing)) do
    inspect(thing)
  end

  defp stringify(thing) when is_binary(thing) do
    thing
  end

  defp stringify(atom) when is_atom(atom) do
    cond do
      function_exported?(atom, :__info__, 1) ->
        Forge.Formats.module(atom)

      function_exported?(atom, :module_info, 0) ->
        Forge.Formats.module(atom)

      true ->
        inspect(atom)
    end
  end

  defp stringify(thing) do
    inspect(thing)
  end

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

  defp build_filter_fn do
    deps_directories = deps_roots()

    fn
      mapped(subtype: :definition, grouping_key: path) ->
        # if we don't have an app name, just make sure we're not
        # in what looks like a deps directory
        not Enum.any?(deps_directories, &String.starts_with?(path, &1))

      _ ->
        false
    end
  end

  defp deps_roots do
    deps_roots(Engine.get_project())
  end

  defp deps_roots(%Project{kind: :mix} = project) do
    # Note: This function assumes that the deps directories for all
    # found projects is `deps`. Projects may override this directory
    # and expert won't understand this. This was done because loading
    # each sub-project is expensive and changes our global directory.

    [Project.root_path(project), "**", "mix.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn relative_mix_path ->
      relative_mix_path
      |> Path.absname()
      |> Path.dirname()
      |> Path.join("deps")
    end)
    |> Enum.filter(&File.exists?/1)
  end

  defp deps_roots(_) do
    []
  end
end
