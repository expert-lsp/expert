Mix.install([{:benchee, "~> 1.5"}])

alias Expert.Search.Store.Backends.Sqlite
alias Forge.Project

defmodule SearchStoreBenchHelper do
  alias Expert.Search.Indexer.Source
  alias Forge.Project

  @copies 50

  def project(name) do
    root = Path.join(System.tmp_dir!(), "expert-search-store-bench-#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    project = Project.new("file://#{root}")
    Project.ensure_workspace(project)
    project
  end

  def runtime_versions do
    %{erlang: System.otp_release(), elixir: System.version()}
  end

  def entries do
    path = Path.expand("../../engine/benchmarks/data/enum.ex", __DIR__)
    source = File.read!(path)
    {:ok, base_entries} = Source.index(path, source)

    for copy <- 1..@copies,
        entry <- base_entries do
      %{entry | id: copied_id(copy, entry.id), path: copied_path(copy)}
    end
  end

  def random_ids(entries, count) do
    entries
    |> Enum.reject(&is_nil(&1.id))
    |> Enum.take_random(count)
    |> Enum.map(& &1.id)
  end

  def before_each(backend, project, entries, entries_by_path) do
    path = entries_by_path |> Map.keys() |> Enum.random()
    {:ok, _deleted_ids} = backend.apply_index_update(project, Map.fetch!(entries_by_path, path), [])

    %{path: path, ids: random_ids(entries, 50)}
  end

  def cleanup(project) do
    File.rm_rf!(Project.workspace_path(project))
  end

  defp copied_path(copy), do: Path.join(__DIR__, "data/enum_#{copy}.ex")

  defp copied_id(_copy, nil), do: nil
  defp copied_id(copy, id), do: copy * 1_000_000 + id
end

{:ok, _started} = Application.ensure_all_started(:exqlite)

project = SearchStoreBenchHelper.project("sqlite")
runtime_versions = SearchStoreBenchHelper.runtime_versions()
Forge.Identifier.start()
{:ok, _application_cache} = Engine.ApplicationCache.start_link([])
{:ok, _module_loader} = Engine.Module.Loader.start_link([])
entries = SearchStoreBenchHelper.entries()
entries_by_path = Enum.group_by(entries, & &1.path)

Sqlite.destroy_all(project)
{:ok, sqlite} = Sqlite.start_link(project, runtime_versions: runtime_versions)
{:ok, :empty} = Sqlite.prepare(sqlite)
:ok = Sqlite.replace_all(project, entries)

Benchee.run(
  %{
    "find_by_subject" => fn _ ->
      Sqlite.find_by_subject(project, Enum, :module, :reference)
    end,
    "find_by_subject, type_wildcard" => fn _ ->
      Sqlite.find_by_subject(project, Enum, :_, :reference)
    end,
    "find_by_subject, subtype_wildcard" => fn _ ->
      Sqlite.find_by_subject(project, Enum, :module, :_)
    end,
    "find_by_subject, two wildcards" => fn _ ->
      Sqlite.find_by_subject(project, Enum, :_, :_)
    end,
    "find_by_subject, subject_wildcard" => fn _ ->
      Sqlite.find_by_subject(project, :_, :module, :reference)
    end,
    "find_by_references" => fn %{ids: ids} ->
      Sqlite.find_by_ids(project, ids, :module, :_)
    end,
    "delete_by_path" => fn %{path: path} ->
      Sqlite.delete_by_path(project, path)
    end
  },
  before_each: fn _ ->
    SearchStoreBenchHelper.before_each(Sqlite, project, entries, entries_by_path)
  end,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "1")),
  time: String.to_integer(System.get_env("BENCH_TIME", "2")),
  memory_time: 0
)

GenServer.stop(sqlite)
SearchStoreBenchHelper.cleanup(project)
