if "--runtime-only" in System.argv() do
  release = to_string(:erlang.system_info(:otp_release))
  version_file = Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"])

  erlang =
    case File.read(version_file) do
      {:ok, text} ->
        case String.split(text, "\n", trim: true) do
          [full] -> full
          _ -> release
        end

      {:error, _} ->
        release
    end

  {:ok, %{elixir: System.version(), erlang: erlang}}
else
  {:ok, _} = Application.ensure_all_started(:mix)
  Mix.env(:test)

  normalize_dependency = fn
    {app, requirement, opts} when is_list(opts) ->
      {app, requirement, Keyword.take(opts, [:app, :only, :path, :targets])}

    {app, opts} when is_list(opts) ->
      {app, Keyword.take(opts, [:app, :only, :path, :targets])}

    dependency ->
      dependency
  end

  # Project code can fail before its dependencies exist. Return that failure to path discovery.
  try do
    configuration =
      Mix.Project.in_project(:expert_indexer, File.cwd!(), [], fn module ->
        config = Mix.Project.config()

        dependency_apps =
          try do
            {:ok, Mix.Project.deps_apps()}
          rescue
            error -> {:error, Exception.message(error)}
          end

        %{
          config: [app: config[:app], deps: Enum.map(config[:deps] || [], normalize_dependency)],
          project_config: Keyword.take(module.project(), [:build_path, :deps_build_path]),
          build_path: Mix.Project.build_path(),
          deps_path: Mix.Project.deps_path(),
          apps_paths: Mix.Project.apps_paths(),
          dependency_apps: dependency_apps,
          env: Mix.env(),
          target: Mix.target(),
          build_root: System.get_env("MIX_BUILD_ROOT")
        }
      end)

    {:ok, configuration}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
|> :erlang.term_to_binary()
|> Base.encode64()
|> IO.puts()
