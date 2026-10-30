{args, _, _} =
  OptionParser.parse(
    System.argv(),
    strict: [
      vsn: :string,
      source_path: :string,
      force: :boolean,
      cache_dir: :string
    ]
  )

expert_vsn = Keyword.fetch!(args, :vsn)
engine_source_path = args |> Keyword.fetch!(:source_path) |> Path.expand()
force? = Keyword.get(args, :force, false)
cache_dir = Keyword.fetch!(args, :cache_dir)

expert_data_path = Path.join(cache_dir, expert_vsn)

elixir_erts_vsn = "elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
tooling_path = Path.join([expert_data_path, elixir_erts_vsn, "tooling"])
mix_home = Path.join(tooling_path, "mix_home")
mix_archives = Path.join(tooling_path, "mix_archives")
rebar_cache = Path.join(tooling_path, "rebar_cache")

for var <- ["MIX_ARCHIVES", "MIX_HOME", "MIX_REBAR3"] do
  if System.get_env(var) == "" do
    System.delete_env(var)
  end
end

# Mix appends every archive to the code path when it starts and protocol
# consolidation reads them all, so the user's archives, which may be compiled
# for another Erlang/OTP version, must stay out of the build.
System.put_env("MIX_HOME", mix_home)
System.put_env("MIX_ARCHIVES", mix_archives)

# Mix's partitioned deps.compile starts fresh OS processes that do not inherit
# the in_project build/deps/lockfile paths used by this script.
System.put_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "1")

System.put_env("REBAR_CACHE_DIR", rebar_cache)

{:ok, _} = Application.ensure_all_started(:elixir)
{:ok, _} = Application.ensure_all_started(:mix)

packaged_deps_path = Path.join(engine_source_path, "deps")
lockfile_path = Path.join(engine_source_path, "mix.lock")

# We use a custom Mix.SCM module to bypass the Hex SCM and allow this script to
# work fully offline. Otherwise Mix will try to use the Hex.SCM which may not be
# available(due to the hex archive not being available) or it may try to connect
# to the internet.
defmodule Expert.BuildEngine.SCM do
  @behaviour Mix.SCM

  @path_scm_opts [:path, :in_umbrella]

  @impl Mix.SCM
  def fetchable?, do: false

  @impl Mix.SCM
  def format(opts), do: opts[:dest]

  @impl Mix.SCM
  def format_lock(_opts), do: nil

  @impl Mix.SCM
  def accepts_options(_app, opts) do
    if !Enum.any?(@path_scm_opts, &Keyword.has_key?(opts, &1)) do
      opts
    end
  end

  @impl Mix.SCM
  def checked_out?(opts), do: File.dir?(opts[:dest])

  @impl Mix.SCM
  def checkout(opts), do: Mix.raise("Missing packaged dependency at #{opts[:dest]}")

  @impl Mix.SCM
  def update(opts), do: opts[:lock]

  @impl Mix.SCM
  def lock_status(_opts), do: :ok

  @impl Mix.SCM
  def equal?(opts1, opts2), do: opts1[:dest] == opts2[:dest]

  @impl Mix.SCM
  def managers(_opts), do: []
end

Mix.SCM.prepend(Expert.BuildEngine.SCM)

workspace_path = Path.join([expert_data_path, elixir_erts_vsn])
build_root_path = Path.join(workspace_path, "_build")

if force? do
  File.rm_rf!(build_root_path)
end

Mix.Project.in_project(
  :engine,
  engine_source_path,
  [
    build_path: build_root_path,
    deps_path: packaged_deps_path,
    lockfile: lockfile_path,
    prune_code_paths: false
  ],
  fn _project_module ->
    Mix.Task.clear()
    Mix.Project.clear_deps_cache()

    Mix.Task.run("deps.compile", ["--no-archives-check"])
    Mix.Task.run("compile", ["--no-archives-check"])
  end
)

mix_env = Mix.env()
dev_build_path = Path.join(build_root_path, to_string(mix_env))
ns_build_path = Path.join([workspace_path, "_build", "#{mix_env}_ns"])

if force? do
  File.rm_rf!(ns_build_path)
end

Mix.Task.run("namespace", [
  dev_build_path,
  ns_build_path,
  "--cwd",
  workspace_path,
  "--no-progress"
])

tooling_env = [
  {"MIX_INSTALL_DIR", expert_data_path},
  {"MIX_HOME", mix_home},
  {"MIX_ARCHIVES", mix_archives},
  {"REBAR_CACHE_DIR", rebar_cache}
]

engine_meta =
  "engine_meta:" <>
    Base.encode64(:erlang.term_to_binary(%{tooling_env: tooling_env, engine_path: ns_build_path}))

IO.puts(engine_meta)
