defmodule Expert.Doctor do
  @moduledoc """
  Diagnoses environment, toolchain, and subsystem health for Expert.
  """

  @success_code 0
  @error_code 1

  @doc """
  Runs health and environment diagnostics.

  Returns exit code 0 if all critical checks pass, or 1 if any failure occurs.
  """
  @spec run([String.t()]) :: non_neg_integer()
  def run(args \\ []) do
    {opts, _rest, _invalid} =
      OptionParser.parse_head(args,
        strict: [help: :boolean, project: :string],
        aliases: [h: :help, p: :project]
      )

    if opts[:help] do
      print_help()
      @success_code
    else
      diagnose(opts)
    end
  end

  defp print_help do
    IO.puts("""
    Diagnose and inspect environment & system health for Expert LSP.

    Usage:
      expert doctor [options]

    Options:
      -p, --project <path>  Inspect a specific project directory (defaults to cwd)
      -h, --help            Show this help message
    """)
  end

  defp diagnose(opts) do
    IO.puts("Expert Doctor v#{version()}\n")

    print_system_info()
    sqlite_ok? = print_subsystems()
    print_global_cache()
    print_project_info(opts[:project] || File.cwd!())

    if sqlite_ok? do
      IO.puts("\nAll critical checks passed.")
      @success_code
    else
      IO.puts("\nCritical subsystem errors detected.")
      @error_code
    end
  end

  defp print_system_info do
    arch = :system_architecture |> :erlang.system_info() |> to_string()
    erts_vsn = :version |> :erlang.system_info() |> to_string()
    jit? = :erlang.system_info(:emu_flavor) == :jit

    IO.puts("""
    System & Runtime:
      OS:                 #{os_name()} (#{arch})
      Elixir:             #{System.version()}
      Erlang/OTP:         #{System.otp_release()} (erts-#{erts_vsn})
      JIT:                #{jit?}
    """)
  end

  defp print_subsystems do
    {sqlite_ok?, sqlite_status} = check_sqlite()
    epmd_status = check_epmd()

    IO.puts("""
    Subsystems:
      SQLite (Exqlite):   #{sqlite_status}
      EPMD Module:        #{epmd_status}
    """)

    sqlite_ok?
  end

  defp print_global_cache do
    cache_dir = Forge.Path.expert_cache_dir()
    engines = Expert.Engine.cached_engine_dirs()
    hex_path = Path.join(cache_dir, "hex.dets")

    engines_summary =
      case engines do
        [] ->
          "0 builds"

        dirs ->
          relative_dirs =
            Enum.map_join(dirs, ", ", fn dir ->
              Path.relative_to(dir, cache_dir)
            end)

          "#{length(dirs)} build(s) (#{relative_dirs})"
      end

    hex_status =
      case File.stat(hex_path) do
        {:ok, %File.Stat{size: size}} -> "present (#{format_bytes(size)})"
        _ -> "not found"
      end

    IO.puts("""
    Global Cache:
      Directory:          #{cache_dir}
      Cached Engines:     #{engines_summary}
      Hex Metadata:       #{hex_status}
    """)
  end

  defp print_project_info(project_dir) do
    project_dir = Path.expand(project_dir)
    mix_file = Path.join(project_dir, "mix.exs")
    expert_dir = Path.join(project_dir, ".expert")

    mix_status = if File.exists?(mix_file), do: "detected", else: "none"

    expert_status =
      if File.dir?(expert_dir) do
        size = dir_size(expert_dir)
        "present (#{format_bytes(size)})"
      else
        "not initialized"
      end

    IO.puts("""
    Project:
      Directory:          #{project_dir}
      Mix Project:        #{mix_status}
      Local .expert:      #{expert_status}
    """)
  end

  defp check_sqlite do
    with {:ok, conn} <- Exqlite.Basic.open(":memory:"),
         result = Exqlite.Basic.exec(conn, "SELECT sqlite_version()"),
         {:ok, [[version]], _columns} <- Exqlite.Basic.rows(result),
         :ok <- Exqlite.Basic.close(conn) do
      {true, "ok (SQLite v#{version})"}
    else
      {:error, reason} ->
        {false, "failed (#{inspect(reason)})"}

      error ->
        {false, "failed (#{inspect(error)})"}
    end
  end

  defp check_epmd do
    configured_epmd =
      case :init.get_argument(:epmd_module) do
        {:ok, [[mod]]} -> List.to_atom(mod)
        _ -> :net_kernel.epmd_module()
      end

    if configured_epmd == Forge.EPMD do
      "ok (#{inspect(Forge.EPMD)})"
    else
      "ok (default epmd)"
    end
  end

  defp os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {:unix, :freebsd} -> "FreeBSD"
      {:win32, _} -> "Windows"
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp dir_size(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        Enum.reduce(files, 0, fn file, acc ->
          path = Path.join(dir, file)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> acc + dir_size(path)
            {:ok, %File.Stat{type: :regular, size: size}} -> acc + size
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  defp version do
    case Expert.vsn() do
      vsn when vsn in ["", "nil", nil] -> "dev"
      vsn -> vsn
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"
end
