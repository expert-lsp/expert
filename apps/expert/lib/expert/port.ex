defmodule Expert.Port do
  @moduledoc """
  Utilities for launching ports in the context of a project.
  """

  alias Expert.Configuration
  alias Forge.Project

  require Logger

  @type open_opt ::
          {:args, [String.t() | charlist()]}
          | {:cd, String.t() | charlist()}
          | {:env, [{:os.env_var_name(), :os.env_var_value()}]}
          | {:line, non_neg_integer()}

  @type open_opts :: [open_opt()]

  @default_unix_path "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  @path_marker "__EXPERT_PATH__"
  @path_fetch_cmd_timeout_ms 5_000
  @slow_path_discovery_ms 1_000

  # These variables are interpreted by release, Elixir, or Erlang launchers and
  # must not leak from Expert's own runtime into project runtime detection.
  @scrubbed_env_vars [
    "ELIXIR_ERL_OPTIONS",
    "ERL_AFLAGS",
    "ERL_FLAGS",
    "ERL_LIBS",
    "ERL_ZFLAGS",
    "ERLEXEC_DIR",
    "RELEASE_ROOT",
    "ROOTDIR",
    "BINDIR",
    "RELEASE_SYS_CONFIG",
    "MIX_ARCHIVES",
    "MIX_INSTALL_DIR",
    "MIX_HOME",
    "MIX_ENV",
    "MIX_REBAR3",
    "REBAR_CACHE_DIR"
  ]

  # Interactive shell discovery may retry once without interactive mode.
  @doc false
  def path_discovery_timeout, do: 2 * @path_fetch_cmd_timeout_ms

  @doc """
  Launches Elixir in a port.

  The executable and environment are resolved from the project context by
  `project_executable/2`.
  """
  @spec open_elixir(Project.t(), open_opts()) :: port() | {:error, :no_elixir, String.t()}
  def open_elixir(%Project{} = project, opts) do
    case project_executable(project, "elixir") do
      {:ok, elixir, env} ->
        opts =
          opts
          |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
          |> put_env(env)

        open_executable(elixir, opts)

      {:error, _name, reason} ->
        Logger.error("Failed to find elixir executable for project: #{reason}")
        {:error, :no_elixir, reason}
    end
  end

  @doc """
  Opens a port for Elixir with a previously resolved executable and environment.
  """
  @spec open_elixir_with_env(charlist(), list(), open_opts()) :: port()
  def open_elixir_with_env(elixir, env, opts) do
    elixir
    |> open_executable(put_env(opts, env))
  end

  @doc """
  Returns the specified executable path and environment for a project.

  Returns `{:ok, executable_path, env}` where:

    * `executable_path` is a charlist path to the specified executable
    * `env` is a list of `{key, value}` tuples for the environment

  Returns `{:error, name, reason}` if no executable can be found.
  """
  @spec project_executable(Project.t(), String.t()) ::
          {:ok, charlist(), list()} | {:error, String.t(), String.t()}
  if Mix.env() == :test do
    # In test mode, the child engine node must use the same Elixir/OTP as the
    # test runner, because the test build produces BEAM files for that specific
    # OTP version. Spawning a login shell to detect the project-local executable
    # can return a different OTP version (e.g. via mise), causing the child to
    # fail to load the test BEAM files.
    def project_executable(%Project{} = project, name) do
      case configured_executable(project, name) do
        {:ok, _executable, _env} = ok -> ok
        :error -> fallback_executable(name)
      end
    end
  else
    def project_executable(%Project{} = project, name) do
      case configured_executable(project, name) do
        {:ok, _executable, _env} = ok ->
          ok

        :error ->
          project_executable_or_fallback(project, name)
      end
    end

    defp project_executable_or_fallback(%Project{} = project, name) do
      case find_project_executable(project, name) do
        {:ok, _executable, _env} = ok ->
          ok

        {:error, ^name, reason} ->
          Logger.warning(
            "Failed to find #{name} for project, falling back to packaged elixir: #{reason}"
          )

          fallback_executable(name)
      end
    end
  end

  @spec find_project_executable(Project.t(), String.t()) ::
          {:ok, charlist(), list()} | {:error, String.t(), String.t()}
  def find_project_executable(%Project{} = project, name) do
    find_project_executable(Forge.OS.os_family(), project, name)
  end

  defp configured_executable(%Project{} = project, name) do
    case configured_executable_path(name) do
      path when is_binary(path) -> {:ok, to_charlist(path), project_environment(project)}
      nil -> :error
    end
  end

  defp configured_executable_path("elixir") do
    Configuration.get().elixir_executable_path
  end

  defp configured_executable_path("erl") do
    Configuration.get().erlang_executable_path
  end

  defp configured_executable_path(_name) do
    nil
  end

  defp fallback_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, name, "Couldn't find any #{name} executable"}
      executable -> {:ok, to_charlist(executable), []}
    end
  end

  defp find_project_executable(:windows, %Project{}, name) do
    path = windows_project_path()

    case find_windows_executable(name, path) do
      false -> {:error, name, "Couldn't find an #{name} executable"}
      executable -> {:ok, executable, sanitized_system_env(path)}
    end
  end

  defp find_project_executable(:unix, %Project{} = project, name) do
    path = unix_project_path(project)

    case :os.find_executable(to_charlist(name), to_charlist(path)) do
      false -> {:error, name, executable_not_found_message(project, name, path)}
      executable -> {:ok, executable, sanitized_system_env(path)}
    end
  end

  defp find_windows_executable(name, path) do
    path = to_charlist(path)

    with false <- :os.find_executable(to_charlist("#{name}.cmd"), path),
         false <- :os.find_executable(to_charlist(name), path) do
      :os.find_executable(to_charlist("#{name}.bat"), path)
    end
  end

  defp executable_not_found_message(%Project{} = project, name, path) do
    root_path = Project.root_path(project)

    case System.get_env("SHELL") do
      nil ->
        "Couldn't find an #{name} executable for project at #{root_path}. Using PATH=#{path}"

      shell ->
        "Couldn't find an #{name} executable for project at #{root_path}. Using shell at #{shell} with PATH=#{path}"
    end
  end

  defp project_environment(%Project{} = project) do
    project
    |> project_path()
    |> sanitized_system_env()
  end

  defp project_path(%Project{} = project) do
    project_path(Forge.OS.os_family(), project)
  end

  defp project_path(:windows, %Project{}) do
    windows_project_path()
  end

  defp project_path(:unix, %Project{} = project) do
    unix_project_path(project)
  end

  defp windows_project_path do
    "PATH"
    |> System.get_env("")
    |> remove_windows_release_root(System.get_env("RELEASE_ROOT"))
  end

  defp remove_windows_release_root(path, nil) do
    path
  end

  defp remove_windows_release_root(path, release_root) do
    release_root = normalize_windows_path(release_root)

    path
    |> String.split(";")
    |> Enum.reject(fn entry ->
      entry
      |> normalize_windows_path()
      |> String.contains?(release_root)
    end)
    |> Enum.join(";")
  end

  defp normalize_windows_path(path) do
    path
    |> String.downcase()
    |> String.replace("/", "\\")
  end

  defp unix_project_path(%Project{} = project) do
    shell = System.get_env("SHELL")

    if shell_available?(shell) do
      shell_project_path(project, shell)
    else
      system_path_without_release_root()
    end
  end

  defp shell_available?(shell) do
    is_binary(shell) and File.exists?(shell)
  end

  defp shell_project_path(%Project{} = project, shell) do
    started_at = System.monotonic_time(:millisecond)

    case path_env_at_directory(Project.root_path(project), shell) do
      {:ok, path} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if elapsed >= @slow_path_discovery_ms do
          Logger.warning(
            "Project PATH discovery using #{shell} took #{elapsed}ms; check shell startup hooks if engine startup is slow",
            project: project
          )
        end

        path

      {:error, :timeout} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        Logger.warning(
          "Project PATH discovery using #{shell} timed out after #{elapsed}ms; falling back to inherited PATH",
          project: project
        )

        system_path_without_release_root()
    end
  end

  defp system_path_without_release_root do
    "PATH"
    |> System.get_env(@default_unix_path)
    |> remove_unix_release_root(System.get_env("RELEASE_ROOT"))
  end

  defp remove_unix_release_root(path, nil) do
    path
  end

  defp remove_unix_release_root(path, release_root) do
    path
    |> String.split(":")
    |> Enum.reject(&String.starts_with?(&1, release_root))
    |> Enum.join(":")
  end

  defp path_env_at_directory(directory, shell) do
    env = [
      {"EXPERT_PROJECT_ROOT", directory},
      {"SHELL_SESSIONS_DISABLE", "1"},
      {"PATH", system_path_without_release_root()}
    ]

    shell
    |> path_fetch_cmd_args()
    |> run_path_fetch_command(shell, env)
  end

  defp path_fetch_cmd_args(shell) do
    case Path.basename(shell) do
      "fish" ->
        cmd =
          "cd \"$EXPERT_PROJECT_ROOT\"; printf \"#{@path_marker}:%s:#{@path_marker}\" (string join ':' $PATH)"

        ["-l", "-c", cmd]

      "nu" ->
        cmd =
          "cd $env.EXPERT_PROJECT_ROOT; print $\"#{@path_marker}:($env.PATH | str join \":\"):#{@path_marker}\""

        ["-l", "-c", cmd]

      _ ->
        cmd =
          "cd \"$EXPERT_PROJECT_ROOT\" && printf \"#{@path_marker}:%s:#{@path_marker}\" \"$PATH\""

        ["-i", "-l", "-c", cmd]
    end
  end

  defp run_path_fetch_command(args, shell, env) do
    case cmd_with_timeout(shell, args, env, @path_fetch_cmd_timeout_ms) do
      {:ok, {output, exit_code}} ->
        {:ok, path_from_output(output, exit_code)}

      {:error, :timeout} ->
        if "-i" in args do
          Logger.warning(
            "Interactive PATH discovery using #{shell} timed out after #{@path_fetch_cmd_timeout_ms}ms; retrying without interactive mode"
          )

          args
          |> List.delete("-i")
          |> run_path_fetch_command(shell, env)
        else
          {:error, :timeout}
        end
    end
  end

  defp path_from_output(output, 0) do
    case Regex.run(~r/#{@path_marker}:(.*?):#{@path_marker}/s, output) do
      [_, path] -> path
      nil -> last_output_line(output)
    end
  end

  defp path_from_output(output, _exit_code) do
    last_output_line(output)
  end

  defp last_output_line(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> List.last()
  end

  defp cmd_with_timeout(shell, args, env, timeout) do
    task = Task.async(fn -> System.cmd(shell, args, env: env) end)

    # Do not add Task.shutdown/1's default five-second grace period to each attempt.
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> {:error, :timeout}
    end
  end

  defp sanitized_system_env(path) do
    path = prepend_configured_erlang_path(path)

    System.get_env()
    |> Enum.reject(fn {key, _value} -> key in @scrubbed_env_vars end)
    |> Enum.map(&sanitize_system_env_var(&1, path))
  end

  defp sanitize_system_env_var({key, _value}, path) when key in ["PATH", "Path"] do
    {key, path}
  end

  defp sanitize_system_env_var({key, value}, _path) do
    {key, value}
  end

  defp prepend_configured_erlang_path(path) do
    case configured_executable_path("erl") do
      erl_path when is_binary(erl_path) -> Path.dirname(erl_path) <> path_env_separator() <> path
      nil -> path
    end
  end

  defp put_env(opts, env) do
    Keyword.update(opts, :env, env, fn old_env -> env ++ old_env end)
  end

  defp open_executable(executable, opts) do
    opts =
      opts
      |> Keyword.update(:env, scrub_env([]), &scrub_env/1)
      |> Keyword.update!(:env, &ensure_charlists/1)

    open_port(Forge.OS.os_type(), executable, opts)
  end

  @doc false
  def scrub_env(env) do
    already_set = MapSet.new(env, fn {key, _value} -> to_string(key) end)

    scrub_entries =
      for var <- @scrubbed_env_vars, var not in already_set do
        {var, ""}
      end

    scrub_entries ++ env
  end

  defp open_port(:win32, executable, opts) do
    if windows_batch_file?(executable) do
      open_windows_batch_file(executable, opts)
    else
      do_open_port(executable, opts)
    end
  end

  defp open_port(:unix, executable, opts) do
    opts =
      Keyword.update(opts, :args, [executable], fn args ->
        [executable | Enum.map(args, &to_string/1)]
      end)

    port_wrapper_path()
    |> do_open_port(opts)
  end

  defp windows_batch_file?(executable) do
    executable
    |> to_string()
    |> String.ends_with?([".cmd", ".bat"])
  end

  defp open_windows_batch_file(executable, opts) do
    executable = to_string(executable)
    launcher = "cmd" |> System.find_executable() |> to_charlist()

    opts =
      opts
      |> Keyword.update(:args, ["/c", "call", executable], fn args ->
        ["/c", "call", executable | args]
      end)

    do_open_port(launcher, [:hide | opts])
  end

  defp do_open_port(executable, opts) do
    Port.open({:spawn_executable, executable}, [:binary, :stderr_to_stdout, :exit_status | opts])
  end

  defp port_wrapper_path do
    with :non_existing <- :code.where_is_file(~c"port_wrapper.sh") do
      :expert
      |> :code.priv_dir()
      |> Path.join("port_wrapper.sh")
      |> Path.expand()
    end
    |> to_string()
  end

  defp ensure_charlists(env) do
    Enum.map(env, fn {key, value} ->
      {key |> to_string() |> String.to_charlist(), value |> to_string() |> String.to_charlist()}
    end)
  end

  defp path_env_separator do
    if Forge.OS.os_family() == :windows, do: ";", else: ":"
  end
end
