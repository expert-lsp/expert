defmodule Expert.Search.Store.State do
  alias Expert.Search.Fuzzy
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger

  defstruct [
    :project,
    :backend,
    :loaded?,
    :load_status,
    :fuzzy,
    :update_buffer
  ]

  def new(%Project{} = project, backend) do
    %__MODULE__{
      backend: backend,
      project: project,
      loaded?: false,
      load_status: :not_loaded,
      update_buffer: %{},
      fuzzy: Fuzzy.from_entries(project, [])
    }
  end

  def drop(%__MODULE__{} = state), do: state.backend.drop(state.project)

  def destroy(%__MODULE__{} = state) do
    with :ok <- state.backend.destroy(state.project) do
      {:ok,
       %__MODULE__{
         state
         | loaded?: false,
           load_status: :not_loaded,
           fuzzy: Fuzzy.from_entries(state.project, []),
           update_buffer: %{}
       }}
    end
  end

  def load(%__MODULE__{loaded?: true} = state), do: {:ok, :loaded, state}

  def load(%__MODULE__{loaded?: false} = state) do
    case state.backend.new(state.project) do
      {:ok, backend_result} ->
        case state.backend.prepare(backend_result) do
          {:ok, :empty} ->
            Logger.info("backend reports empty")
            {:ok, :empty, %__MODULE__{state | loaded?: true, load_status: :empty}}

          {:ok, :stale} ->
            Logger.info("backend reports stale")

            with %__MODULE__{} = state <-
                   initialize_fuzzy(%__MODULE__{state | loaded?: true, load_status: :stale}) do
              {:ok, :stale, state}
            end

          error ->
            Logger.error("Could not initialize index due to #{inspect(error)}")
            error
        end

      error ->
        Logger.error("Could not initialize index backend due to #{inspect(error)}")
        error
    end
  end

  def replace(%__MODULE__{} = state, entries) do
    with :ok <- state.backend.replace_all(state.project, entries),
         {:ok, fuzzy} <- Fuzzy.from_backend(state.project, state.backend),
         :ok <- maybe_sync(state) do
      {:ok,
       %__MODULE__{
         state
         | loaded?: true,
           load_status: :ready,
           fuzzy: fuzzy
       }}
    end
  end

  def exact(%__MODULE__{loaded?: false}, _subject, _constraints), do: {:error, :loading}

  def exact(%__MODULE__{} = state, subject, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_subject(state.project, subject, type, subtype) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def exact_many(%__MODULE__{loaded?: false}, _subjects, _constraints), do: {:error, :loading}

  def exact_many(%__MODULE__{} = state, subjects, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_subjects(state.project, subjects, type, subtype) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def by_caller(%__MODULE__{loaded?: false}, _caller, _path, _constraints), do: {:error, :loading}

  def by_caller(%__MODULE__{} = state, caller, path, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_caller(state.project, caller, path, type, subtype) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def prefix(%__MODULE__{loaded?: false}, _prefix, _constraints), do: {:error, :loading}

  def prefix(%__MODULE__{} = state, prefix, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_prefix(state.project, prefix, type, subtype) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def fuzzy(%__MODULE__{loaded?: false}, _subject, _constraints), do: {:error, :loading}

  def fuzzy(%__MODULE__{} = state, subject, constraints) do
    case Fuzzy.match(state.fuzzy, subject) do
      [] ->
        {:ok, []}

      ids ->
        type = Keyword.get(constraints, :type, :_)
        subtype = Keyword.get(constraints, :subtype, :_)

        case state.backend.find_by_ids(state.project, ids, type, subtype) do
          l when is_list(l) -> {:ok, l}
          error -> error
        end
    end
  end

  def all(%__MODULE__{loaded?: false}, _), do: {:error, :loading}

  def all(%__MODULE__{} = state, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)
    paths = Keyword.get(constraints, :paths, :_)

    case all_entries(state, paths, type, subtype) do
      {:error, _} = error -> error
      entries -> {:ok, entries}
    end
  end

  defp all_entries(state, :_, type, subtype) do
    state.backend.find_by_subject(state.project, :_, type, subtype)
  end

  defp all_entries(state, paths, type, subtype) when is_list(paths) do
    state.backend.find_by_paths(state.project, paths, type, subtype)
  end

  def path_to_ids(%__MODULE__{} = state) do
    state.backend.path_to_ids(state.project)
  end

  def resolve_mfa(%__MODULE__{} = state, module, function, arity) do
    mfa = Forge.Formats.mfa(module, function, arity)

    case exact(state, mfa, subtype: :definition) do
      {:ok,
       [
         %Entry{
           type: {:function, :delegate},
           metadata: %{
             original_module: original_module,
             original_function: original_function,
             original_arity: original_arity
           }
         }
         | _
       ]} ->
        {original_module, original_function, original_arity, true, true}

      {:ok, [%Entry{type: {:function, :delegate}, metadata: %{original_mfa: original_mfa}} | _]} ->
        case Forge.Code.parse_mfa(original_mfa) do
          {target_module, target_fun, target_arity} ->
            {target_module, target_fun, target_arity, true, true}

          nil ->
            {module, function, arity, true, false}
        end

      {:ok, [%Entry{type: {:function, _}} | _]} ->
        {module, function, arity, true, false}

      _ ->
        {module, function, arity, false, false}
    end
  end

  def siblings(%__MODULE__{loaded?: false}, _entry), do: {:error, :loading}

  def siblings(%__MODULE__{} = state, entry) do
    case state.backend.siblings(state.project, entry) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def parent(%__MODULE__{loaded?: false}, _entry), do: {:error, :loading}

  def parent(%__MODULE__{} = state, entry) do
    case state.backend.parent(state.project, entry) do
      %Entry{} = entry -> {:ok, entry}
      error -> error
    end
  end

  def buffer_updates(%__MODULE__{} = state, path, entries) do
    %__MODULE__{state | update_buffer: Map.put(state.update_buffer, path, entries)}
  end

  def drop_buffered_updates(%__MODULE__{} = state), do: %__MODULE__{state | update_buffer: %{}}

  def flush_buffered_updates(%__MODULE__{update_buffer: buffer} = state)
      when map_size(buffer) == 0 do
    maybe_sync(state)
    {:ok, state}
  end

  def flush_buffered_updates(%__MODULE__{} = state) do
    result =
      Enum.reduce_while(state.update_buffer, state, fn {path, entries}, state ->
        case update_nosync(state, path, entries) do
          {:ok, new_state} -> {:cont, new_state}
          error -> {:halt, error}
        end
      end)

    with %__MODULE__{} = state <- result,
         :ok <- maybe_sync(state) do
      {:ok, drop_buffered_updates(state)}
    end
  end

  def update_nosync(%__MODULE__{} = state, path, entries) do
    with {:ok, deleted_ids} <-
           state.backend.apply_index_update(state.project, entries, [path]) do
      fuzzy =
        state.fuzzy
        |> Fuzzy.drop_values(deleted_ids)
        |> Fuzzy.add(entries)

      {:ok,
       %__MODULE__{
         state
         | loaded?: true,
           load_status: :ready,
           fuzzy: fuzzy
       }}
    end
  end

  def apply_index_update(
        %__MODULE__{} = state,
        updated_entries,
        paths_to_clear
      ) do
    with {:ok, deleted_ids} <-
           state.backend.apply_index_update(state.project, updated_entries, paths_to_clear),
         :ok <- maybe_sync(state) do
      fuzzy =
        state.fuzzy
        |> Fuzzy.drop_values(deleted_ids)
        |> Fuzzy.add(updated_entries)

      {:ok,
       %__MODULE__{
         state
         | loaded?: true,
           load_status: :ready,
           fuzzy: fuzzy
       }}
    end
  end

  defp maybe_sync(%__MODULE__{} = state) do
    if function_exported?(state.backend, :sync, 1),
      do: state.backend.sync(state.project),
      else: :ok
  end

  defp initialize_fuzzy(%__MODULE__{} = state) do
    case Fuzzy.from_backend(state.project, state.backend) do
      {:ok, fuzzy} -> %__MODULE__{state | fuzzy: fuzzy}
      {:error, _} = error -> error
    end
  end
end
