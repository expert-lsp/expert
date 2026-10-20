defmodule Expert.Search.Store.Backends.Sqlite do
  @behaviour Expert.Search.Store.Backend

  use GenServer

  alias Expert.EngineApi
  alias Expert.Search.Store.Backend
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Entry
  require Logger

  @schema_version 7
  @database_file "source.index.sqlite3"
  @slow_query_threshold_ms 500
  # NOTE(doorgan): SQLite has a variable limit of 32766. Entry batches use 7 params
  # per entry. 4000 entries per batch is 28000 params per batch, below SQLite's
  # limit.
  @sqlite_variable_limit 32_766
  @insert_batch_size 4_000
  @file_id_of_path "(SELECT id FROM files WHERE path = ?)"
  @entries_select """
  SELECT
    entries.id,
    files.path,
    entries.subject,
    entries.caller,
    types.type,
    entries.block_id,
    entry_blobs.entry
  FROM entries
  JOIN entry_blobs ON entry_blobs.entry_key = entries.entry_key
  JOIN files ON files.id = entries.file_id
  JOIN types ON types.id = entries.type_id
  """
  @refs_select """
  SELECT files.path, refs.subject, refs.caller, types.type, refs.occurrences
  FROM refs
  JOIN files ON files.id = refs.file_id
  JOIN types ON types.id = refs.type_id
  """
  @busy_timeout_ms Application.compile_env(:expert, :search_store_sqlite_busy_timeout_ms, 5_000)

  defmodule State do
    defstruct [:conn, :database_path, :project, :runtime_versions]
  end

  @impl Backend
  def new(%Project{} = project) do
    case Process.whereis(name(project)) do
      nil -> {:error, :not_started}
      pid -> {:ok, pid}
    end
  end

  @impl Backend
  def prepare(pid), do: GenServer.call(pid, :prepare, :infinity)

  @impl Backend
  def sync(%Project{} = project), do: GenServer.call(name(project), :sync, :infinity)

  @impl Backend
  def insert(%Project{} = project, entries) do
    GenServer.call(name(project), {:insert, entries}, :infinity)
  end

  @impl Backend
  def drop(%Project{} = project), do: GenServer.call(name(project), :drop, :infinity)

  @impl Backend
  def destroy(%Project{} = project) do
    if pid = Process.whereis(name(project)) do
      GenServer.call(pid, :destroy, :infinity)
    else
      :ok
    end
  end

  def destroy_all(%Project{} = project), do: project |> root_path() |> File.rm_rf!()

  @impl Backend
  def path_to_ids(%Project{} = project) do
    GenServer.call(name(project), :path_to_ids, :infinity)
  end

  @impl Backend
  def definitions_for_fuzzy(%Project{} = project) do
    GenServer.call(name(project), :definitions_for_fuzzy, :infinity)
  end

  @impl Backend
  def replace_all(%Project{} = project, entries) when is_list(entries) do
    replacement = fn write_batch ->
      with :ok <- write_batch.(entries) do
        {:ok, :ok}
      end
    end

    case replace_all(project, replacement) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def replace_all(%Project{} = project, replacement) when is_function(replacement, 1) do
    GenServer.call(name(project), {:replace_all, replacement}, :infinity)
  end

  @impl Backend
  def apply_index_update(%Project{} = project, updated_entries, paths_to_clear) do
    GenServer.call(
      name(project),
      {:apply_index_update, updated_entries, paths_to_clear},
      :infinity
    )
  end

  def apply_index_update(pid_or_name, updated_entries, paths_to_clear) do
    GenServer.call(
      pid_or_name,
      {:apply_index_update, updated_entries, paths_to_clear},
      :infinity
    )
  end

  @impl Backend
  def delete_by_path(%Project{} = project, path) do
    GenServer.call(name(project), {:delete_by_path, path}, :infinity)
  end

  @impl Backend
  def find_by_subject(%Project{} = project, subject, type, subtype) do
    GenServer.call(name(project), {:find_by_subject, subject, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_subjects(%Project{} = project, subjects, type, subtype) when is_list(subjects) do
    GenServer.call(name(project), {:find_by_subjects, subjects, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_caller(%Project{} = project, caller, path, type, subtype)
      when is_binary(caller) and is_binary(path) do
    GenServer.call(name(project), {:find_by_caller, caller, path, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_prefix(%Project{} = project, prefix, type, subtype) do
    GenServer.call(name(project), {:find_by_prefix, prefix, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_ids(%Project{} = project, ids, type, subtype) do
    GenServer.call(name(project), {:find_by_ids, ids, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_paths(%Project{} = project, paths, type, subtype) when is_list(paths) do
    GenServer.call(name(project), {:find_by_paths, paths, type, subtype}, :infinity)
  end

  @impl Backend
  def structure_for_path(%Project{} = project, path) do
    GenServer.call(name(project), {:structure_for_path, path}, :infinity)
  end

  @impl Backend
  def siblings(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:siblings, entry}, :infinity)
  end

  @impl Backend
  def parent(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:parent, entry}, :infinity)
  end

  def start_link(%Project{} = project), do: start_link(project, [])

  def start_link(%Project{} = project, opts) when is_list(opts) do
    gen_server_opts =
      case Keyword.get(opts, :name, name(project)) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, [project, opts], gen_server_opts)
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def child_spec([%Project{} = project | opts]) when is_list(opts) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project, opts]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::search_sqlite_backend"

  def database_path(%Project{} = project, runtime_versions) do
    project
    |> root_path(runtime_versions)
    |> Path.join(@database_file)
  end

  if Mix.env() == :test do
    def root_path(%Project{} = project) do
      Project.workspace_path(project, ["indexes", "sqlite", to_string(Project.entropy(project))])
    end
  else
    def root_path(%Project{} = project),
      do: Project.workspace_path(project, ["indexes", "sqlite"])
  end

  def root_path(%Project{} = project, runtime_versions) do
    Path.join([root_path(project), runtime_versions.erlang, runtime_versions.elixir])
  end

  @impl GenServer
  def init([%Project{} = project, opts]) do
    Process.flag(:fullsweep_after, 5)

    runtime_versions = runtime_versions(project, opts)
    database_path = database_path(project, runtime_versions)

    {:ok,
     %State{
       database_path: database_path,
       project: project,
       runtime_versions: runtime_versions
     }}
  end

  @impl GenServer
  def handle_call(:prepare, _from, %State{} = state) do
    {reply, new_state} = prepare_database(state)
    {:reply, reply, new_state}
  end

  def handle_call(:sync, _from, %State{} = state) do
    {:reply, sync_database(state), state}
  end

  def handle_call(:drop, _from, %State{} = state), do: reply(do_drop(state), state)

  def handle_call({:insert, entries}, _from, %State{} = state),
    do: reply(do_insert(state, entries), state)

  def handle_call(:path_to_ids, _from, %State{} = state),
    do: reply(do_path_to_ids(state), state)

  def handle_call(:definitions_for_fuzzy, _from, %State{} = state),
    do: reply(do_find_definitions_for_fuzzy(state), state)

  def handle_call({:replace_all, replacement}, _from, %State{} = state),
    do: reply(do_replace_all(state, replacement), state)

  def handle_call(
        {:apply_index_update, updated_entries, paths_to_clear},
        _from,
        %State{} = state
      ) do
    reply(do_apply_index_update(state, updated_entries, paths_to_clear), state)
  end

  def handle_call({:delete_by_path, path}, _from, %State{} = state),
    do: reply(do_delete_by_path(state, path), state)

  def handle_call({:find_by_subject, subject, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_subject(state, subject, type, subtype), state)

  def handle_call({:find_by_subjects, subjects, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_subjects(state, subjects, type, subtype), state)

  def handle_call({:find_by_caller, caller, path, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_caller(state, caller, path, type, subtype), state)

  def handle_call({:find_by_prefix, prefix, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_prefix(state, prefix, type, subtype), state)

  def handle_call({:find_by_ids, ids, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_ids(state, ids, type, subtype), state)

  def handle_call({:find_by_paths, paths, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_paths(state, paths, type, subtype), state)

  def handle_call({:structure_for_path, path}, _from, %State{} = state),
    do: reply(do_structure_for_path(state, path), state)

  def handle_call({:siblings, entry}, _from, %State{} = state),
    do: reply(do_siblings(state, entry), state)

  def handle_call({:parent, entry}, _from, %State{} = state),
    do: reply(do_parent(state, entry), state)

  def handle_call(:destroy, _from, %State{} = state) do
    case reset_database_schema(state) do
      {:ok, _status} -> reply(:ok, state)
      {:error, _} = error -> reply(error, state)
    end
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    close_database(state)
    state
  end

  def do_drop(%State{}), do: :ok

  def do_insert(%State{} = state, entries) when is_list(entries) do
    transaction(state, fn ->
      insert_entries(state, entries)
    end)
  end

  def do_path_to_ids(%State{} = state) do
    # One index seek per file and table, rather than a GROUP BY over every entry.
    sql = """
    SELECT path, MAX(COALESCE(definition_id, 0), COALESCE(reference_id, 0))
    FROM (
      SELECT
        files.path,
        (SELECT MAX(id) FROM entries WHERE entries.file_id = files.id) AS definition_id,
        (SELECT MAX(max_id) FROM refs WHERE refs.file_id = files.id) AS reference_id
      FROM files
    )
    WHERE definition_id IS NOT NULL OR reference_id IS NOT NULL
    """

    case query(state, sql) do
      {:ok, rows} -> Map.new(rows, fn [path, id] -> {path, id} end)
      {:error, _} = error -> error
    end
  end

  def do_find_definitions_for_fuzzy(%State{} = state) do
    sql = """
    SELECT entries.id, files.path, entries.subject, types.type
    FROM entries
    JOIN files ON files.id = entries.file_id
    JOIN types ON types.id = entries.type_id
    """

    case query(state, sql) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, path, subject, type_blob] ->
          %Entry{
            id: id,
            path: path,
            subject: subject,
            type: decode_term(type_blob),
            subtype: :definition
          }
        end)

      {:error, _} = error ->
        error
    end
  end

  def do_replace_all(%State{} = state, replacement) when is_function(replacement, 1) do
    with {:ok, result} <- transaction(state, fn -> replace_entries(state, replacement) end),
         :ok <- exec(state, "PRAGMA optimize = 0x10002") do
      {:ok, result}
    end
  end

  defp replace_entries(%State{} = state, replacement) do
    with :ok <- drop_indexes(state),
         :ok <- exec(state, "DELETE FROM entry_blobs"),
         :ok <- exec(state, "DELETE FROM entries"),
         :ok <- exec(state, "DELETE FROM refs"),
         :ok <- exec(state, "DELETE FROM files"),
         :ok <- exec(state, "DELETE FROM types"),
         :ok <- exec(state, "DELETE FROM structures"),
         {:ok, result} <- replacement.(fn entries -> insert_entries(state, entries) end),
         :ok <- create_indexes(state) do
      {:ok, result}
    end
  end

  def do_apply_index_update(%State{} = state, update, paths_to_clear)
      when is_function(update, 1) and is_list(paths_to_clear) do
    transaction(state, fn ->
      with {:ok, deleted_ids} <- delete_entries_for_paths(state, paths_to_clear),
           :ok <- delete_structures_for_paths(state, paths_to_clear),
           {:ok, result} <- update.(fn entries -> insert_entries(state, entries) end) do
        {:ok, deleted_ids, result}
      end
    end)
  end

  def do_apply_index_update(%State{} = state, updated_entries, paths_to_clear)
      when is_list(updated_entries) and is_list(paths_to_clear) do
    paths = affected_paths(updated_entries, paths_to_clear)

    if paths == [] do
      {:ok, []}
    else
      commit_index_update(state, updated_entries, paths)
    end
  end

  defp commit_index_update(%State{} = state, updated_entries, paths) do
    transaction(state, fn ->
      with {:ok, deleted_ids} <- delete_entries_for_paths(state, paths),
           :ok <- delete_structures_for_paths(state, paths),
           :ok <- insert_entries(state, updated_entries) do
        {:ok, deleted_ids}
      end
    end)
  end

  def do_delete_by_path(%State{} = state, path) do
    transaction(state, fn ->
      with {:ok, ids_to_delete} <- delete_entries_for_paths(state, [path]),
           :ok <- delete_structures_for_paths(state, [path]) do
        {:ok, ids_to_delete}
      end
    end)
  end

  def do_find_by_subject(%State{} = state, subject, type, subtype) do
    {clauses, args} = subject_constraint(subject)
    selector = if subject == :_, do: :all, else: {:subject, subject_key(subject)}
    find(state, selector, clauses, args, type, subtype)
  end

  def do_find_by_subjects(%State{} = state, subjects, type, subtype) when is_list(subjects) do
    result =
      subjects
      |> Enum.map(&subject_key/1)
      |> Enum.uniq()
      |> Stream.chunk_every(query_chunk_size(type, subtype))
      |> Enum.reduce_while([], fn subjects, batches ->
        selector = {:subjects, subjects}

        case find(
               state,
               selector,
               ["subject IN (#{placeholders(subjects)})"],
               subjects,
               type,
               subtype
             ) do
          entries when is_list(entries) -> {:cont, [entries | batches]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error -> error
      batches -> batches |> Enum.reverse() |> List.flatten()
    end
  end

  def do_find_by_caller(%State{} = state, caller, path, type, subtype) do
    selector = {:caller, caller}

    find(
      state,
      selector,
      ["caller = ? AND file_id = #{@file_id_of_path}"],
      [caller, path],
      type,
      subtype
    )
  end

  def do_find_by_prefix(%State{} = state, prefix, type, subtype) do
    {clauses, args} = prefix_constraint(prefix)
    selector = if prefix == :_, do: :all, else: {:prefix, subject_key(prefix)}
    find(state, selector, clauses, args, type, subtype)
  end

  # Definitions are kept in `entries` and references, grouped, in `refs`.
  # `selector` says which entries the clauses select, to filter the module
  # references that are read back from call rows.
  defp find(%State{} = state, selector, clauses, args, type, subtype) do
    Enum.reduce_while(tables_for(subtype), [], fn table, found ->
      case table_entries(state, table, selector, clauses, args, type) do
        entries when is_list(entries) -> {:cont, found ++ entries}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp tables_for(:_), do: [:entries, :refs]
  defp tables_for(:definition), do: [:entries]
  defp tables_for(:reference), do: [:refs]
  defp tables_for(_other), do: []

  defp table_entries(%State{} = state, :entries, _selector, clauses, args, type) do
    {clauses, args} = add_type_constraint(clauses, args, type)
    state |> query_entries(where_clause(Enum.join(clauses, " AND ")), args) |> entries_result()
  end

  defp table_entries(%State{} = state, :refs, selector, clauses, args, type) do
    queries = [
      add_type_constraint(clauses, args, type) | call_queries(selector, clauses, args, type)
    ]

    result =
      Enum.reduce_while(queries, [], fn {clauses, args}, found ->
        state
        |> query_refs(where_clause(Enum.join(clauses, " AND ")), args)
        |> refs_result()
        |> case do
          entries when is_list(entries) -> {:cont, found ++ entries}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      entries when is_list(entries) -> Enum.filter(entries, selected?(selector, type))
      {:error, _} = error -> error
    end
  end

  # Module references kept with calls are on the calls' rows, found by the
  # `module` column, so queries that can return them also read those rows.
  defp call_queries(_selector, _clauses, _args, type) when type not in [:_, :module], do: []
  defp call_queries({:subject, key}, _clauses, _args, _type), do: [{["module = ?"], [key]}]

  defp call_queries({:subjects, keys}, _clauses, _args, _type),
    do: [{["module IN (#{placeholders(keys)})"], keys}]

  defp call_queries({:prefix, key}, _clauses, _args, :module),
    do: [{["module LIKE ? ESCAPE '\\'"], [like_prefix(key)]}]

  defp call_queries(_selector, clauses, args, :module),
    do: [{clauses ++ ["module IS NOT NULL"], args}]

  defp call_queries(_selector, _clauses, _args, :_), do: []

  defp selected?(selector, type) do
    matches_selector = selector_matcher(selector)
    fn %Entry{} = entry -> (type == :_ or entry.type == type) and matches_selector.(entry) end
  end

  defp selector_matcher(:all), do: fn _entry -> true end
  defp selector_matcher(:paths), do: fn _entry -> true end
  defp selector_matcher({:subject, key}), do: &(subject_key(&1.subject) == key)
  defp selector_matcher({:prefix, key}), do: &String.starts_with?(subject_key(&1.subject), key)
  defp selector_matcher({:caller, caller}), do: &(&1.caller == caller)

  defp selector_matcher({:subjects, keys}) do
    keys = MapSet.new(keys)
    &MapSet.member?(keys, subject_key(&1.subject))
  end

  # Only definitions are looked up by id, so references are not indexed by it.
  def do_find_by_ids(%State{} = state, ids, type, subtype) when is_list(ids) do
    case ids do
      [] ->
        []

      [_ | _] when subtype not in [:_, :definition] ->
        []

      [_ | _] ->
        {clauses, args} = add_type_constraint(["entries.id IN (#{placeholders(ids)})"], ids, type)
        where = Enum.join(clauses, " AND ")

        with {:ok, rows} <-
               query(
                 state,
                 """
                 #{@entries_select}
                 #{where_clause(where)}
                 ORDER BY entries.entry_key
                 """,
                 args
               ) do
          entries_by_id =
            Enum.group_by(
              rows,
              fn [id | _rest] -> id end,
              &decode_entry/1
            )

          Enum.flat_map(ids, fn id -> Map.get(entries_by_id, id, []) end)
        end
    end
  end

  def do_find_by_paths(%State{}, [], _type, _subtype), do: []

  def do_find_by_paths(%State{} = state, paths, type, subtype) when is_list(paths) do
    result =
      paths
      |> Enum.uniq()
      |> Stream.chunk_every(query_chunk_size(type, subtype))
      |> Enum.reduce_while([], fn paths, batches ->
        case find_by_path_chunk(state, paths, type, subtype) do
          entries when is_list(entries) -> {:cont, [entries | batches]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _} = error -> error
      batches -> batches |> Enum.reverse() |> List.flatten()
    end
  end

  def do_structure_for_path(%State{} = state, path) do
    case query(state, "SELECT structure FROM structures WHERE path = ? LIMIT 1", [path]) do
      {:ok, [[structure_blob]]} -> {:ok, decode_term(structure_blob)}
      {:ok, []} -> :error
      {:error, _} = error -> error
    end
  end

  def do_siblings(%State{} = state, %Entry{} = entry) do
    block_id = block_id_key(entry.block_id)

    with {:ok, rows} <-
           query(
             state,
             """
             #{@entries_select}
             WHERE entries.block_id = ? AND entries.file_id = #{@file_id_of_path}
             ORDER BY entries.id
             """,
             [block_id, entry.path]
           ),
         {:ok, references} <- block_references(state, entry, block_id) do
      rows
      |> Enum.map(&decode_entry/1)
      |> Enum.concat(references)
      |> Enum.sort_by(& &1.id)
      |> Enum.filter(&same_block_type?(entry, &1))
      |> Enum.uniq()
      |> then(&{:ok, &1})
    end
  end

  # References are never blocks, so blocks have none as siblings.
  defp block_references(%State{}, %Entry{} = entry, _block_id) when Entry.is_block(entry),
    do: {:ok, []}

  defp block_references(%State{} = state, %Entry{} = entry, block_id) do
    state
    |> query_refs("WHERE refs.file_id = #{@file_id_of_path}", [entry.path])
    |> refs_result()
    |> case do
      references when is_list(references) ->
        {:ok, Enum.filter(references, &(block_id_key(&1.block_id) == block_id))}

      {:error, _} = error ->
        error
    end
  end

  def do_parent(%State{} = state, %Entry{} = entry) do
    with {:ok, structure} <- do_structure_for_path(state, entry.path),
         {:ok, child_path} <- child_path(structure, entry.block_id) do
      child_path = if Entry.is_block(entry), do: tl(child_path), else: child_path
      find_first_by_block_id(state, child_path)
    end
  end

  def do_parent(%State{}, :root), do: :error

  def do_destroy(%State{} = state) do
    with :ok <- close_database(state) do
      remove_database_root(state)
    end
  end

  defp reply(result, %State{} = state), do: {:reply, result, state}

  defp prepare_database(%State{} = state) do
    if state.conn do
      prepare_open_database(state)
    else
      open_database(state)
    end
  end

  defp open_database(%State{} = state) do
    with :ok <- ensure_database_directory(state),
         {:ok, conn} <- Exqlite.Basic.open(state.database_path) do
      state = %State{state | conn: conn}
      prepare_open_database(state)
    else
      {:error, _} = error ->
        {error, state}
    end
  end

  defp prepare_open_database(%State{} = state) do
    case initialize_schema(state) do
      {:ok, status} ->
        {{:ok, status}, state}

      {:error, reason} = error ->
        if recoverable_database_error?(reason) do
          reset_database_file(state)
        else
          {error, state}
        end
    end
  end

  defp initialize_schema(%State{} = state) do
    with :ok <- configure_database(state),
         :ok <- create_schema_table(state),
         {:ok, current_version} <- current_schema_version(state),
         {:ok, status} <- load_or_reset_schema(state, current_version),
         :ok <- exec(state, "PRAGMA optimize = 0x10002") do
      {:ok, status}
    end
  end

  defp configure_database(%State{} = state) do
    with :ok <- exec(state, "PRAGMA busy_timeout = #{@busy_timeout_ms}"),
         :ok <- exec(state, "PRAGMA synchronous = NORMAL") do
      exec(state, "PRAGMA case_sensitive_like = ON")
    end
  end

  defp load_or_reset_schema(%State{} = state, @schema_version), do: load_status(state)
  defp load_or_reset_schema(%State{} = state, nil), do: reset_schema(state)
  defp load_or_reset_schema(%State{} = state, _version), do: reset_database_schema(state)

  defp create_schema_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS schema (
      id INTEGER PRIMARY KEY,
      version INTEGER NOT NULL,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """)
  end

  defp current_schema_version(%State{} = state) do
    case query(state, "SELECT MAX(version) FROM schema") do
      {:ok, [[version]]} -> {:ok, version}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp reset_schema(%State{} = state) do
    with :ok <- exec(state, "DROP TABLE IF EXISTS entries"),
         :ok <- exec(state, "DROP TABLE IF EXISTS entry_blobs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS refs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS ref_blobs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS files"),
         :ok <- exec(state, "DROP TABLE IF EXISTS types"),
         :ok <- exec(state, "DROP TABLE IF EXISTS structures"),
         :ok <- create_entries_table(state),
         :ok <- create_refs_table(state),
         :ok <- create_files_table(state),
         :ok <- create_types_table(state),
         :ok <- create_entry_blobs_table(state),
         :ok <- create_structures_table(state),
         :ok <- create_indexes(state),
         :ok <- exec(state, "INSERT INTO schema (version) VALUES (?)", [@schema_version]) do
      {:ok, :empty}
    end
  end

  defp reset_database_schema(%State{} = state) do
    with :ok <- exec(state, "DROP TABLE IF EXISTS schema"),
         :ok <- exec(state, "DROP TABLE IF EXISTS entries"),
         :ok <- exec(state, "DROP TABLE IF EXISTS entry_blobs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS refs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS ref_blobs"),
         :ok <- exec(state, "DROP TABLE IF EXISTS files"),
         :ok <- exec(state, "DROP TABLE IF EXISTS types"),
         :ok <- exec(state, "DROP TABLE IF EXISTS structures"),
         :ok <- create_schema_table(state) do
      reset_schema(state)
    end
  end

  defp load_status(%State{} = state) do
    with :ok <- create_entries_table(state),
         :ok <- create_refs_table(state),
         :ok <- create_files_table(state),
         :ok <- create_types_table(state),
         :ok <- create_entry_blobs_table(state),
         :ok <- create_structures_table(state),
         :ok <- create_indexes(state),
         {:ok, result} <-
           query(state, "SELECT 1 FROM entries UNION ALL SELECT 1 FROM refs LIMIT 1") do
      case result do
        [] -> {:ok, :empty}
        [[1]] -> {:ok, :stale}
      end
    end
  end

  defp create_entries_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS entries (
      entry_key INTEGER PRIMARY KEY,
      id INTEGER NOT NULL,
      file_id INTEGER NOT NULL,
      subject TEXT NOT NULL,
      caller TEXT,
      type_id INTEGER NOT NULL,
      block_id INTEGER NOT NULL
    )
    """)
  end

  # References, one row per file, subject, type and caller, with their
  # occurrences: a few dozen bytes each, small enough to keep in the row.
  defp create_refs_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS refs (
      ref_key INTEGER PRIMARY KEY,
      file_id INTEGER NOT NULL,
      subject TEXT NOT NULL,
      caller TEXT,
      type_id INTEGER NOT NULL,
      max_id INTEGER NOT NULL,
      module TEXT,
      occurrences BLOB NOT NULL
    )
    """)
  end

  defp create_types_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS types (
      id INTEGER PRIMARY KEY,
      type BLOB NOT NULL UNIQUE
    )
    """)
  end

  # Each file's path is stored once, and entries refer to it by id: the path
  # would otherwise be repeated in every entry and in four of its indexes.
  defp create_files_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE
    )
    """)
  end

  defp create_entry_blobs_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS entry_blobs (
      entry_key INTEGER PRIMARY KEY,
      entry BLOB NOT NULL
    )
    """)
  end

  defp create_structures_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS structures (
      path TEXT PRIMARY KEY,
      structure BLOB NOT NULL
    )
    """)
  end

  @indexes [
    # covers looking definitions up by subject, and listing them for fuzzy search
    "entries_definitions_idx ON entries (subject, id, file_id, type_id)",
    "entries_caller_idx ON entries (caller, file_id, type_id) WHERE caller IS NOT NULL",
    "entries_id_idx ON entries (id, type_id)",
    "entries_file_block_idx ON entries (file_id, block_id, id)",
    "entries_type_idx ON entries (type_id)",
    "refs_subject_idx ON refs (subject, type_id)",
    "refs_caller_idx ON refs (caller, file_id, type_id) WHERE caller IS NOT NULL",
    "refs_file_idx ON refs (file_id, max_id)",
    # the module of the calls whose module references are kept with them
    "refs_module_idx ON refs (module) WHERE module IS NOT NULL"
  ]

  defp create_indexes(%State{} = state) do
    Enum.reduce_while(@indexes, :ok, fn index, :ok ->
      case exec(state, "CREATE INDEX IF NOT EXISTS " <> index) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp drop_indexes(%State{} = state) do
    Enum.reduce_while(@indexes, :ok, fn index, :ok ->
      [name | _] = String.split(index, " ", parts: 2)

      case exec(state, "DROP INDEX IF EXISTS " <> name) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl Backend
  def encode_entries(entries) do
    {entries, folded} = fold_module_references(entries)

    {order, groups} =
      Enum.reduce(entries, {[], %{}}, fn
        %Entry{} = entry, {order, groups} when Entry.is_structure(entry) ->
          {[entry | order], groups}

        %Entry{subtype: :reference} = entry, {order, groups} ->
          group = {entry.subject, entry.caller, entry.type, entry.path}

          case groups do
            %{^group => references} -> {order, %{groups | group => [entry | references]}}
            %{} -> {[{:refs, group} | order], Map.put(groups, group, [entry])}
          end

        %Entry{} = entry, {order, groups} ->
          {[entry | order], groups}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn
      {:refs, group} ->
        [first | _] = references = groups |> Map.fetch!(group) |> Enum.reverse()
        {:encoded, first, {:refs, refs_args(references, folded)}}

      %Entry{} = entry when Entry.is_structure(entry) ->
        {:encoded, entry, nil}

      %Entry{} = entry ->
        {:encoded, entry, encode_row(entry)}
    end)
  end

  # The `Mod` of a `Mod.fun()` call is a reference to `Mod` that starts where
  # the call does. Instead of a row of its own, it is kept with the call's
  # occurrence, and comes back as its own entry when the call is read.
  defp fold_module_references(entries) do
    calls =
      for %Entry{subtype: :reference, type: {:function, :usage}, range: %Range{} = range} = call <-
            entries,
          into: %{},
          do: {{call.path, range.start.line, range.start.character}, call}

    if map_size(calls) == 0 do
      {entries, %{}}
    else
      Enum.flat_map_reduce(entries, %{}, fn
        %Entry{subtype: :reference, type: :module, subject: module, range: %Range{} = range} =
            reference,
        folded
        when is_atom(module) ->
          with %Entry{} = call <-
                 Map.get(calls, {reference.path, range.start.line, range.start.character}),
               true <- call_module_key(call.subject) == subject_key(module),
               false <- Map.has_key?(folded, call.id) do
            {[], Map.put(folded, call.id, reference)}
          else
            _ -> {[reference], folded}
          end

        entry, folded ->
          {[entry], folded}
      end)
    end
  end

  # "Mod.Sub.fun/2" -> "Mod.Sub"
  defp call_module_key(subject) when is_binary(subject) do
    with [name | _] <- String.split(subject, "/", parts: 2),
         [_ | _] = dots <- :binary.matches(name, ".") do
      {at, _} = List.last(dots)
      binary_part(name, 0, at)
    else
      _ -> nil
    end
  end

  defp call_module_key(_subject), do: nil

  # Occurrences are stored as terms inside the row's blob rather than as blobs
  # of their own, so they are encoded and decoded once.
  defp refs_args([%Entry{} = first | _] = references, folded) do
    {occurrences, max_id} =
      Enum.map_reduce(references, first.id, fn %Entry{} = entry, max_id ->
        occurrence = {entry.id, block_id_key(entry.block_id), entry_term(entry)}

        case Map.fetch(folded, entry.id) do
          {:ok, %Entry{} = module} ->
            module_occurrence =
              {module.id, block_id_key(module.block_id), module.caller, entry_term(module)}

            {Tuple.insert_at(occurrence, 3, module_occurrence),
             Enum.max([entry.id, module.id, max_id])}

          :error ->
            {occurrence, max(entry.id, max_id)}
        end
      end)

    module =
      if Enum.any?(references, &Map.has_key?(folded, &1.id)), do: call_module_key(first.subject)

    [
      first.path,
      subject_key(first.subject),
      first.caller,
      blob(first.type),
      max_id,
      module,
      blob(occurrences)
    ]
  end

  defp insert_entries(%State{} = state, entries) do
    %{structures: structures, refs: refs, definitions: definitions} =
      entries
      |> Enum.group_by(&row_kind/1)
      |> Map.merge(%{structures: [], refs: [], definitions: []}, fn _kind, rows, [] -> rows end)

    structures = Enum.map(structures, &entry_of/1)
    {plain_refs, encoded_refs} = Enum.split_with(refs, &match?(%Entry{}, &1))
    refs = encoded_refs ++ encode_entries(plain_refs)

    with :ok <- insert_entry_batches(state, definitions),
         :ok <- insert_ref_batches(state, refs) do
      insert_structures(state, structures)
    end
  end

  defp row_kind({:encoded, _entry, {:refs, _args}}), do: :refs
  defp row_kind({:encoded, entry, _row}), do: row_kind(entry)
  defp row_kind(%Entry{} = entry) when Entry.is_structure(entry), do: :structures
  defp row_kind(%Entry{subtype: :reference}), do: :refs
  defp row_kind(%Entry{subtype: :definition}), do: :definitions

  defp row_kind(%Entry{subtype: subtype}),
    do:
      raise(
        ArgumentError,
        "entries can only be definitions or references, got #{inspect(subtype)}"
      )

  defp insert_entry_batches(%State{}, []), do: :ok

  defp insert_entry_batches(%State{} = state, entries) do
    entries
    |> Stream.chunk_every(@insert_batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case insert_entry_batch(state, batch) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp insert_entry_batch(%State{} = state, batch) do
    rows = encode_rows(batch)

    with {:ok, entry_key} <- next_entry_key(state),
         {:ok, file_ids} <- file_ids(state, Enum.map(rows, fn {[_id, path | _], _} -> path end)),
         {:ok, type_ids} <-
           type_ids(state, Enum.map(rows, fn {[_, _, _, _, type | _], _} -> type end)) do
      rows =
        rows
        |> Enum.map(fn {[id, path, subject, caller, type, block_id], blob} ->
          {[id, Map.get(file_ids, path), subject, caller, Map.get(type_ids, type), block_id],
           blob}
        end)
        |> Enum.with_index(entry_key)

      with :ok <- insert_entry_rows(state, rows) do
        insert_entry_blobs(state, rows)
      end
    end
  end

  defp entry_of({:encoded, entry, _row}), do: entry
  defp entry_of(%Entry{} = entry), do: entry

  defp insert_ref_batches(%State{}, []), do: :ok

  defp insert_ref_batches(%State{} = state, refs) do
    refs
    |> Stream.chunk_every(@insert_batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case insert_ref_batch(
             state,
             Enum.map(batch, fn {:encoded, _entry, {:refs, args}} -> args end)
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp insert_ref_batch(%State{} = state, rows) do
    with {:ok, file_ids} <- file_ids(state, Enum.map(rows, &hd/1)),
         {:ok, type_ids} <- type_ids(state, Enum.map(rows, &Enum.at(&1, 3))) do
      args =
        Enum.flat_map(rows, fn [path, subject, caller, type, max_id, module, occurrences] ->
          [
            Map.fetch!(file_ids, path),
            subject,
            caller,
            Map.fetch!(type_ids, type),
            max_id,
            module,
            occurrences
          ]
        end)

      sql = """
      INSERT INTO refs (file_id, subject, caller, type_id, max_id, module, occurrences)
      VALUES #{row_placeholders(rows, 7)}
      """

      exec(state, sql, args)
    end
  end

  defp encode_rows(batch), do: Enum.map(batch, &encode_row/1)

  defp encode_row({:encoded, _entry, row}), do: row

  defp encode_row(%Entry{} = entry) do
    {entry_args(entry), build_entry_blob(entry)}
  end

  defp next_entry_key(%State{} = state) do
    case query(state, "SELECT COALESCE(MAX(entry_key), 0) + 1 FROM entries") do
      {:ok, [[entry_key]]} -> {:ok, entry_key}
      {:error, _} = error -> error
    end
  end

  defp file_ids(%State{} = state, paths) do
    paths = Enum.uniq(paths)

    with :ok <-
           exec(
             state,
             "INSERT OR IGNORE INTO files (path) VALUES #{row_placeholders(paths, 1)}",
             paths
           ),
         {:ok, found} <-
           query(
             state,
             "SELECT path, id FROM files WHERE path IN (#{placeholders(paths)})",
             paths
           ) do
      {:ok, Map.new(found, fn [path, id] -> {path, id} end)}
    end
  end

  defp type_ids(%State{} = state, types) do
    types = Enum.uniq(types)

    with :ok <-
           exec(
             state,
             "INSERT OR IGNORE INTO types (type) VALUES #{row_placeholders(types, 1)}",
             types
           ),
         {:ok, found} <-
           query(
             state,
             "SELECT type, id FROM types WHERE type IN (#{placeholders(types)})",
             types
           ) do
      {:ok, Map.new(found, fn [type, id] -> {{:blob, type}, id} end)}
    end
  end

  defp insert_entry_rows(%State{} = state, rows) do
    sql = """
    INSERT INTO entries (entry_key, id, file_id, subject, caller, type_id, block_id)
    VALUES #{row_placeholders(rows, 7)}
    """

    args =
      Enum.flat_map(rows, fn {{entry_args, _blob}, entry_key} -> [entry_key | entry_args] end)

    exec(state, sql, args)
  end

  defp insert_entry_blobs(%State{} = state, rows) do
    sql = "INSERT INTO entry_blobs (entry_key, entry) VALUES #{row_placeholders(rows, 2)}"
    args = Enum.flat_map(rows, fn {{_entry_args, blob}, entry_key} -> [entry_key, blob] end)

    exec(state, sql, args)
  end

  defp insert_structures(%State{}, []), do: :ok

  defp insert_structures(%State{} = state, structures) do
    structures
    |> Enum.chunk_every(@insert_batch_size)
    |> Enum.reduce_while(:ok, fn structures, :ok ->
      case insert_structure_batch(state, structures) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp insert_structure_batch(%State{} = state, structures) do
    sql =
      "INSERT OR REPLACE INTO structures (path, structure) VALUES #{row_placeholders(structures, 2)}"

    args = Enum.flat_map(structures, fn entry -> [entry.path, blob(entry.subject)] end)

    exec(state, sql, args)
  end

  defp entry_args(%Entry{} = entry) do
    [
      entry.id,
      entry.path,
      subject_key(entry.subject),
      entry.caller,
      blob(entry.type),
      block_id_key(entry.block_id)
    ]
  end

  defp affected_paths(updated_entries, paths_to_clear) do
    updated_entries
    |> Enum.map(& &1.path)
    |> Kernel.++(paths_to_clear)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp delete_entries_for_paths(%State{}, []), do: {:ok, []}

  defp delete_entries_for_paths(%State{} = state, paths) do
    with {:ok, rows} <-
           query(
             state,
             "SELECT entry_key, id FROM entries WHERE file_id IN (#{file_ids_of_paths(paths)})",
             paths
           ),
         {:ok, reference_rows} <-
           query(
             state,
             "SELECT occurrences FROM refs WHERE file_id IN (#{file_ids_of_paths(paths)})",
             paths
           ),
         :ok <- delete_entry_blobs_for_rows(state, rows),
         :ok <-
           exec(
             state,
             "DELETE FROM entries WHERE file_id IN (#{file_ids_of_paths(paths)})",
             paths
           ),
         :ok <-
           exec(state, "DELETE FROM refs WHERE file_id IN (#{file_ids_of_paths(paths)})", paths),
         :ok <- exec(state, "DELETE FROM files WHERE path IN (#{placeholders(paths)})", paths) do
      reference_ids =
        Enum.flat_map(reference_rows, &occurrence_ids/1)

      deleted_ids =
        rows
        |> Enum.map(fn [_entry_key, id] -> id end)
        |> Enum.concat(reference_ids)
        |> Enum.reject(&is_nil/1)

      {:ok, deleted_ids}
    end
  end

  defp occurrence_ids([occurrences]) do
    Enum.flat_map(decode_term(occurrences), fn
      {id, _block_id, _term} -> [id]
      {id, _block_id, _term, {module_id, _, _, _}} -> [id, module_id]
    end)
  end

  defp delete_entry_blobs_for_rows(%State{}, []), do: :ok

  defp delete_entry_blobs_for_rows(%State{} = state, rows) do
    rows
    |> Stream.chunk_every(@sqlite_variable_limit)
    |> Enum.reduce_while(:ok, fn rows, :ok ->
      entry_keys = Enum.map(rows, fn [entry_key, _id] -> entry_key end)

      case exec(
             state,
             "DELETE FROM entry_blobs WHERE entry_key IN (#{placeholders(entry_keys)})",
             entry_keys
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp delete_structures_for_paths(%State{}, []), do: :ok

  defp delete_structures_for_paths(%State{} = state, paths) do
    exec(state, "DELETE FROM structures WHERE path IN (#{placeholders(paths)})", paths)
  end

  defp query_entries(%State{} = state, where, args) do
    query(state, @entries_select <> where, args)
  end

  defp query_refs(%State{} = state, where, args) do
    query(state, @refs_select <> where, args)
  end

  defp find_by_path_chunk(%State{} = state, paths, type, subtype) do
    find(
      state,
      :paths,
      ["file_id IN (SELECT id FROM files WHERE path IN (#{placeholders(paths)}))"],
      paths,
      type,
      subtype
    )
  end

  defp query_chunk_size(type, subtype) do
    @sqlite_variable_limit - Enum.count([type, subtype], &(&1 != :_))
  end

  defp entries_result({:ok, rows}) do
    Enum.map(rows, &decode_entry/1)
  end

  defp entries_result({:error, _} = error), do: error

  defp refs_result({:ok, rows}), do: Enum.flat_map(rows, &decode_references/1)

  defp refs_result({:error, _} = error), do: error

  defp file_ids_of_paths(paths), do: "SELECT id FROM files WHERE path IN (#{placeholders(paths)})"

  defp where_clause(""), do: ""
  defp where_clause(where), do: "WHERE #{where}"

  defp placeholders(values), do: Enum.map_join(values, ", ", fn _ -> "?" end)

  defp row_placeholders(rows, columns) do
    row = "(" <> placeholders(1..columns) <> ")"
    Enum.map_join(rows, ", ", fn _ -> row end)
  end

  defp subject_constraint(:_), do: {[], []}
  defp subject_constraint(subject), do: {["subject = ?"], [subject_key(subject)]}

  defp prefix_constraint(:_), do: {[], []}

  defp prefix_constraint(prefix) do
    {["subject LIKE ? ESCAPE '\\'"], [like_prefix(subject_key(prefix))]}
  end

  defp add_type_constraint(clauses, args, :_), do: {clauses, args}

  defp add_type_constraint(clauses, args, value),
    do: {clauses ++ ["type_id = (SELECT id FROM types WHERE type = ?)"], args ++ [blob(value)]}

  defp transaction(%State{} = state, fun) do
    with :ok <- exec(state, "BEGIN IMMEDIATE") do
      case fun.() do
        :ok ->
          commit_transaction(state, :ok)

        {:ok, _} = result ->
          commit_transaction(state, result)

        {:ok, _, _} = result ->
          commit_transaction(state, result)

        {:error, _} = error ->
          exec(state, "ROLLBACK")
          error
      end
    end
  end

  defp commit_transaction(%State{} = state, result) do
    case exec(state, "COMMIT") do
      :ok ->
        result

      {:error, _} = error ->
        exec(state, "ROLLBACK")
        error
    end
  end

  defp sync_database(%State{conn: nil}), do: :ok
  defp sync_database(%State{}), do: :ok

  defp close_database(%State{conn: nil}), do: :ok
  defp close_database(%State{conn: conn}), do: Exqlite.Basic.close(conn)

  defp remove_database_root(%State{} = state) do
    case File.rm_rf(root_path(state.project, state.runtime_versions)) do
      {:ok, _paths} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp reset_database_file(%State{} = state) do
    with :ok <- close_database(state),
         :ok <- remove_database_files(state),
         :ok <- ensure_database_directory(state),
         {:ok, conn} <- Exqlite.Basic.open(state.database_path) do
      state = %State{state | conn: conn}

      case initialize_schema(state) do
        {:ok, status} -> {{:ok, status}, state}
        {:error, _} = error -> {error, state}
      end
    else
      {:error, _} = error -> {error, %State{state | conn: nil}}
    end
  end

  defp remove_database_files(%State{} = state) do
    state.database_path
    |> database_files()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end

  defp database_files(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
  end

  defp ensure_database_directory(%State{} = state) do
    directory = Path.dirname(state.database_path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, :eexist} -> if File.dir?(directory), do: :ok, else: {:error, {:eexist, directory}}
      {:error, reason} -> {:error, {reason, directory}}
    end
  end

  defp recoverable_database_error?(%{__struct__: Exqlite.Error, message: message}) do
    message in ["database disk image is malformed", "file is not a database"]
  end

  defp recoverable_database_error?(_reason), do: false

  defp exec(%State{} = state, statement, args \\ []) do
    timed(state, statement, args, fn ->
      case Exqlite.Basic.exec(state.conn, statement, args) do
        {:error, reason, _details} -> {:error, reason}
        result -> rows_to_ok(result)
      end
    end)
  end

  defp query(%State{} = state, statement, args \\ []) do
    timed(state, statement, args, fn ->
      case Exqlite.Basic.exec(state.conn, statement, args) do
        {:error, reason, _details} -> {:error, reason}
        result -> rows(result)
      end
    end)
  end

  defp timed(%State{} = state, statement, args, fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if elapsed_ms > @slow_query_threshold_ms do
      log_slow_query(state, statement, args, elapsed_ms)
    end

    result
  end

  defp log_slow_query(%State{} = state, statement, args, elapsed_ms) do
    query = String.trim(statement)

    case Exqlite.Basic.exec(state.conn, "EXPLAIN QUERY PLAN #{statement}", args) do
      {:error, _reason, _details} ->
        Logger.warning("[SQL SLOW] #{elapsed_ms}ms | #{query}")

      result ->
        case Exqlite.Basic.rows(result) do
          {:ok, [], _columns} ->
            Logger.warning("[SQL SLOW] #{elapsed_ms}ms | #{query}")

          {:ok, rows, _columns} ->
            plan =
              Enum.map_join(rows, "\n", fn row ->
                "  " <> Enum.map_join(row, " | ", &to_string/1)
              end)

            Logger.warning("[SQL SLOW] #{elapsed_ms}ms | #{query}\nEXPLAIN QUERY PLAN:\n#{plan}")

          {:error, _reason} ->
            Logger.warning("[SQL SLOW] #{elapsed_ms}ms | #{query}")
        end
    end
  end

  defp rows_to_ok(result) do
    case Exqlite.Basic.rows(result) do
      {:ok, _rows, _columns} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rows(result) do
    case Exqlite.Basic.rows(result) do
      {:ok, rows, _columns} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp child_path(structure, child_id) do
    path =
      Enum.reduce_while(structure, [], fn
        {^child_id, _children}, children ->
          {:halt, [child_id | children]}

        {_, children}, path when map_size(children) == 0 ->
          {:cont, path}

        {current_id, children}, path ->
          case child_path(children, child_id) do
            {:ok, child_path} -> {:halt, [current_id | path] ++ Enum.reverse(child_path)}
            :error -> {:cont, path}
          end
      end)

    case path do
      [] -> :error
      path -> {:ok, Enum.reverse(path)}
    end
  end

  defp find_first_by_block_id(%State{} = state, block_ids) do
    Enum.reduce_while(block_ids, :error, fn block_id, failure ->
      case do_find_by_ids(state, [block_id], :_, :_) do
        [entry] -> {:halt, {:ok, entry}}
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, failure}
      end
    end)
  end

  defp like_prefix(prefix) do
    prefix
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> Kernel.<>("%")
  end

  defp subject_key(:_), do: :_
  defp subject_key(subject) when is_binary(subject), do: subject
  defp subject_key(subject) when is_atom(subject), do: inspect(subject)
  defp subject_key(subject) when is_list(subject), do: List.to_string(subject)
  defp subject_key(subject), do: inspect(subject)

  defp block_id_key(:root), do: 0
  defp block_id_key(nil), do: 0
  defp block_id_key(block_id) when is_integer(block_id), do: block_id

  defp block_id(0), do: :root
  defp block_id(block_id) when is_integer(block_id), do: block_id

  # Every position carries its whole source line, and an entry's four
  # positions usually share one or two lines, so each line is stored once and
  # positions refer to it by index.
  defp build_entry_blob(%Entry{} = entry), do: entry |> entry_term() |> blob()

  defp entry_term(%Entry{} = entry) do
    subject_override = if !is_binary(entry.subject), do: entry.subject
    {lines, block_range} = compact_range(entry.block_range, [])
    {lines, range} = compact_range(entry.range, lines)

    {
      subject_override,
      entry.application,
      lines |> Enum.reverse() |> List.to_tuple(),
      block_range,
      range,
      entry.metadata
    }
  end

  defp decode_entry([id, path, subject_key, caller, type_blob, block_id, entry_blob]) do
    decode_entry(
      id,
      path,
      subject_key,
      caller,
      decode_term(type_blob),
      :definition,
      block_id,
      decode_term(entry_blob)
    )
  end

  defp decode_references([path, subject_key, caller, type_blob, occurrences]) do
    type = decode_term(type_blob)

    Enum.flat_map(decode_term(occurrences), fn
      {id, block_id, entry_term} ->
        [decode_entry(id, path, subject_key, caller, type, :reference, block_id, entry_term)]

      {id, block_id, entry_term, {module_id, module_block_id, module_caller, module_term}} ->
        [
          decode_entry(id, path, subject_key, caller, type, :reference, block_id, entry_term),
          decode_entry(
            module_id,
            path,
            nil,
            module_caller,
            :module,
            :reference,
            module_block_id,
            module_term
          )
        ]
    end)
  end

  defp decode_entry(id, path, subject_key, caller, type, subtype, block_id, entry_term) do
    {subject_override, application, lines, block_range, range, metadata} = entry_term
    block_range = expand_range(block_range, lines)
    range = expand_range(range, lines)

    subject =
      case subject_override do
        nil -> subject_key
        subject -> subject
      end

    %Entry{
      application: application,
      id: id,
      block_id: block_id(block_id),
      block_range: block_range,
      path: path,
      range: range,
      subject: subject,
      caller: caller,
      subtype: subtype,
      type: type,
      metadata: metadata
    }
  end

  defp compact_range(nil, lines), do: {lines, nil}

  defp compact_range(%Range{start: start_position, end: end_position}, lines) do
    {lines, start_position} = compact_position(start_position, lines)
    {lines, end_position} = compact_position(end_position, lines)
    {lines, {start_position, end_position}}
  end

  # `lines` is in reverse order, so a line's index is counted from the end.
  defp compact_position(%Position{} = position, lines) do
    {lines, line_index} = line_index(lines, position.context_line)

    {lines,
     {
       position.line,
       position.character,
       position.valid?,
       line_index,
       position.document_line_count,
       position.starting_index
     }}
  end

  defp line_index(lines, line) do
    count = length(lines)

    case Enum.find_index(lines, &(&1 == line)) do
      nil -> {[line | lines], count}
      reversed_index -> {lines, count - 1 - reversed_index}
    end
  end

  defp expand_range(nil, _lines), do: nil

  defp expand_range({start_position, end_position}, lines) do
    %Range{
      start: expand_position(start_position, lines),
      end: expand_position(end_position, lines)
    }
  end

  defp expand_position(
         {line, character, valid?, line_index, document_line_count, starting_index},
         lines
       ) do
    %Position{
      line: line,
      character: character,
      valid?: valid?,
      context_line: elem(lines, line_index),
      document_line_count: document_line_count,
      starting_index: starting_index
    }
  end

  defp blob(term), do: {:blob, encode_term(term)}

  # Stored terms are a few hundred bytes at most, where setting up compression
  # costs far more than it saves.
  defp encode_term(term), do: :erlang.term_to_binary(term)
  defp decode_term(binary), do: :erlang.binary_to_term(binary)

  defp same_block_type?(left_entry, right_entry),
    do: Entry.is_block(left_entry) == Entry.is_block(right_entry)

  defp runtime_versions(%Project{} = project, opts) do
    Keyword.get_lazy(opts, :runtime_versions, fn -> EngineApi.runtime_versions(project) end)
  end
end
