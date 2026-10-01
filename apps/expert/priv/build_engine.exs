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
engine_source_path = Keyword.fetch!(args, :source_path)
force? = Keyword.get(args, :force, false)
cache_dir = Keyword.fetch!(args, :cache_dir)

expert_data_path = Path.join(cache_dir, expert_vsn)

elixir_erts_vsn = "elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
tooling_path = Path.join([expert_data_path, "tooling", elixir_erts_vsn])
mix_home = Path.join(tooling_path, "mix_home")
mix_archives = Path.join(tooling_path, "mix_archives")
rebar_cache = Path.join(tooling_path, "rebar_cache")

System.put_env("MIX_INSTALL_DIR", expert_data_path)
System.put_env("MIX_HOME", mix_home)
System.put_env("MIX_ARCHIVES", mix_archives)
System.put_env("REBAR_CACHE_DIR", rebar_cache)

{:ok, _} = Application.ensure_all_started(:elixir)
{:ok, _} = Application.ensure_all_started(:mix)

Mix.Task.run("local.hex", ["--if-missing", "--force"])
Mix.Task.run("local.rebar", ["--if-missing", "--force"])

Mix.install([{:engine, path: engine_source_path, env: :prod}],
  start_applications: false,
  config_path: Path.join(engine_source_path, "config/config.exs"),
  lockfile: Path.join(engine_source_path, "mix.lock"),
  force: force?
)

install_path =
  with false <- Version.match?(System.version(), ">= 1.16.2"),
       false <- is_nil(Process.whereis(Mix.State)),
       cache_id <- Mix.State.get(:installed) do
    install_root =
      System.get_env("MIX_INSTALL_DIR") || Path.join(Mix.Utils.mix_cache(), "installs")

    version = "elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
    Path.join([install_root, version, cache_id])
  else
    _ -> Mix.install_project_dir()
  end

dev_build_path = Path.join([install_path, "_build", "dev"])
ns_build_path = Path.join([install_path, "_build", "dev_ns"])

Mix.Task.run("namespace", [dev_build_path, ns_build_path, "--cwd", install_path, "--no-progress"])

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
