defmodule Engine.CodeMod.Format.Cache do
  @moduledoc """
  A read-through cache of formatters, keyed by file path.

  Two public ETS tables are used:

  - `entries` — one row per unique `{opts, extension}` combination, keyed by a
    generated entry ID. Stores the `Entry` struct once, shared across all files
    that resolve to the same config.

  - `paths` — one row per cached file path, keyed by path. Stores only the
    entry ID so the formatter data is never duplicated.

  A lookup reads the path row to get the entry ID, then reads the entry row to
  get the formatter and opts. On a path miss the caller scans the entries table
  to find a matching entry (by extension and `:inputs` glob) without going to
  the GenServer; only a full entry miss requires a GenServer call to resolve.

  On a cadence, the known `.formatter.exs` files are checked for stat changes.
  When one is detected, both tables are cleared and entries re-resolve lazily.
  """

  use GenServer

  import Forge.Logging
  import Record

  alias Engine.CodeMod.Format
  alias Engine.CodeMod.Format.Resolver
  alias Forge.Document
  alias Forge.Project

  require Logger

  # -- State -------------------------------------------------------------------

  defmodule State do
    @moduledoc false

    defstruct project: nil, refresh_interval: nil, dot_formatters: %{}

    @type dot_formatters :: %{Path.t() => File.Stat.t()}
    @type t :: %__MODULE__{
            project: Forge.Project.t(),
            refresh_interval: non_neg_integer(),
            dot_formatters: dot_formatters()
          }

    @spec new(Forge.Project.t(), non_neg_integer()) :: t()
    def new(%Forge.Project{} = project, refresh_interval) do
      %__MODULE__{project: project, refresh_interval: refresh_interval}
    end

    @spec put_dot_formatters(t(), dot_formatters()) :: t()
    def put_dot_formatters(%__MODULE__{} = state, dot_formatters) do
      %__MODULE__{state | dot_formatters: dot_formatters}
    end
  end

  # -- ETS table --------------------------------------------------------------

  @formatters_table :"#{__MODULE__}.Formatters"
  # keypos: 2 — records are {tag, field1, field2, ...} so field1 is at position 2
  @table_opts [:named_table, :public, :set, read_concurrency: true, keypos: 2]

  @default_refresh_interval :timer.seconds(10)

  # -- Records (ETS row formats) -----------------------------------------------

  defrecordp :formatter_row, path: nil, formatter: nil, opts: nil

  @type formatter_row ::
          record(:formatter_row,
            path: Path.t(),
            formatter: Format.formatter_function(),
            opts: keyword()
          )

  # -- Public API --------------------------------------------------------------

  @spec fetch_formatter(Project.t(), Path.t()) ::
          {:ok, Format.formatter_function(), keyword()} | :error
  def fetch_formatter(%Project{} = project, file_path) do
    case fetch(file_path) do
      {:ok, _, _} = result ->
        Logger.debug("formatter cache hit for #{file_path}")
        result

      :error ->
        Logger.debug("formatter cache miss for #{file_path}")

        timed_log("formatter cache miss (call + resolve) for #{file_path}", fn ->
          GenServer.call(__MODULE__, {:resolve, project, file_path})
        end)
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- GenServer ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@formatters_table, @table_opts)
    project = Keyword.get_lazy(opts, :project, &Engine.get_project/0)
    interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)
    schedule_refresh(interval)

    {:ok, State.new(project, interval), {:continue, :discover_dot_formatters}}
  end

  @impl GenServer
  def handle_continue(:discover_dot_formatters, %State{} = state) do
    {:noreply, State.put_dot_formatters(state, discover_dot_formatters(state.project))}
  end

  @impl GenServer
  def handle_call({:resolve, %Project{} = project, file_path}, _from, %State{} = state) do
    {:reply, find_or_resolve(project, file_path), state}
  end

  @impl GenServer
  def handle_info(:refresh, %State{} = state) do
    new_state =
      if dot_formatters_changed?(state.dot_formatters) do
        dot_formatters =
          timed_log(".formatter.exs scan", fn ->
            discover_dot_formatters(state.project)
          end)

        Logger.info("formatter config changed, clearing cache")
        :ets.delete_all_objects(@formatters_table)

        State.put_dot_formatters(state, dot_formatters)
      else
        state
      end

    clean_closed_entries()
    schedule_refresh(state.refresh_interval)

    {:noreply, new_state}
  end

  # -- Private -----------------------------------------------------------------

  @spec find_or_resolve(Project.t(), Path.t()) ::
          {:ok, Format.formatter_function(), keyword()} | :error
  defp find_or_resolve(%Project{} = project, file_path) do
    case fetch(file_path) do
      {:ok, _, _} = result -> result
      :error -> resolve_and_store(project, file_path)
    end
  end

  @spec resolve_and_store(Project.t(), Path.t()) ::
          {:ok, Format.formatter_function(), keyword()} | :error
  defp resolve_and_store(%Project{} = project, file_path) do
    {formatter, opts} = Resolver.resolve(project, file_path)

    true =
      :ets.insert(
        @formatters_table,
        formatter_row(path: file_path, formatter: formatter, opts: opts)
      )

    {:ok, formatter, opts}
  rescue
    exception ->
      formatted_stack = Exception.format(:error, exception, __STACKTRACE__)
      Logger.warning(["Could not resolve formatter for ", file_path, ": ", formatted_stack])

      :error
  end

  @spec fetch(Path.t()) :: {:ok, Format.formatter_function(), keyword()} | :error
  defp fetch(file_path) do
    case :ets.lookup(@formatters_table, file_path) do
      [formatter_row(formatter: formatter, opts: opts)] ->
        {:ok, formatter, opts}

      [] ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @spec dot_formatters_changed?(State.dot_formatters()) :: boolean()
  defp dot_formatters_changed?(dot_formatters) do
    timed_log(".formatter.exs mtime check", fn ->
      Enum.any?(dot_formatters, fn {path, stored_stat} ->
        case File.stat(path, time: :posix) do
          {:ok, stat} -> stat != stored_stat
          {:error, _} -> true
        end
      end)
    end)
  end

  @spec discover_dot_formatters(Project.t()) :: State.dot_formatters()
  defp discover_dot_formatters(%Project{} = project) do
    case Project.root_path(project) do
      nil ->
        %{}

      root_path ->
        discover_dot_formatters_at_path(root_path, %{})
    end
  end

  @spec discover_dot_formatters_at_path(Path.t(), State.dot_formatters()) ::
          State.dot_formatters()
  defp discover_dot_formatters_at_path(dir, dot_formatters) do
    formatter_exs = Path.join(dir, ".formatter.exs")

    case File.stat(formatter_exs, time: :posix) do
      {:ok, stat} ->
        dot_formatters = Map.put(dot_formatters, formatter_exs, stat)

        formatter_exs
        |> subdirectories_from_formatter_config()
        |> Enum.reduce(dot_formatters, fn sub, acc ->
          discover_dot_formatters_at_path(sub, acc)
        end)

      {:error, _} ->
        dot_formatters
    end
  end

  @spec subdirectories_from_formatter_config(Path.t()) :: [Path.t()]
  defp subdirectories_from_formatter_config(formatter_exs) do
    {terms, _binding} = Code.eval_file(formatter_exs)
    subdirectories = Keyword.get(terms, :subdirectories) || []
    base_directory = Path.dirname(formatter_exs)

    Enum.flat_map(subdirectories, fn subdirectory ->
      base_directory
      |> Path.join(subdirectory)
      |> Path.wildcard()
    end)
  rescue
    _ -> []
  end

  @spec schedule_refresh(non_neg_integer()) :: reference()
  defp schedule_refresh(interval) do
    Process.send_after(self(), :refresh, interval)
  end

  defp clean_closed_entries do
    @formatters_table
    |> :ets.tab2list()
    |> Enum.each(fn formatter_row(path: path) ->
      if not (path |> Document.Path.to_uri() |> Document.Store.open?()) do
        true = :ets.delete(@formatters_table, path)
      end
    end)
  end
end
