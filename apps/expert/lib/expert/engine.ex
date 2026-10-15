defmodule Expert.Engine do
  @moduledoc """
  Utilities for managing Expert engine builds.

  When Expert builds the engine for a project, it caches the build in the user
  data directory. If engine dependencies change (e.g., in nightly builds), a
  cached build may become stale and cause errors.

  This module provides functions to inspect and clean these cached builds.
  """

  @doc """
  Runs engine management commands based on parsed arguments.

  Returns the exit code for the command. Clean operations will stop at the
  first deletion error and return exit code 1.
  """

  @success_code 0
  @error_code 1

  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    {opts, subcommand, _invalid} =
      OptionParser.parse_head(args,
        strict: [help: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      print_help()
    else
      case subcommand do
        ["ls" | ls_opts] -> list_engines(ls_opts)
        ["clean" | clean_opts] -> clean_engines(clean_opts)
        [unknown | _] -> print_unknown_subcommand(unknown)
        [] -> print_help()
      end
    end
  end

  @spec list_engines([String.t()]) :: non_neg_integer()
  defp list_engines(ls_options) do
    {opts, _rest, _invalid} =
      OptionParser.parse_head(ls_options,
        strict: [help: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      print_ls_help()
    else
      print_engine_dirs()
    end
  end

  @spec print_engine_dirs() :: non_neg_integer()
  defp print_engine_dirs do
    dirs = get_engine_dirs()

    case dirs do
      [] ->
        print_no_engines_found()

      dirs ->
        Enum.each(dirs, &IO.puts/1)
    end

    @success_code
  end

  @spec clean_engines([String.t()]) :: non_neg_integer()
  defp clean_engines(clean_options) do
    {opts, _rest, _invalid} =
      OptionParser.parse_head(clean_options,
        strict: [force: :boolean, help: :boolean],
        aliases: [f: :force, h: :help]
      )

    dirs = get_engine_dirs()

    cond do
      opts[:help] ->
        print_clean_help()

      dirs == [] ->
        print_no_engines_found()

      opts[:force] ->
        clean_all_force(dirs)

      true ->
        clean_interactive(dirs)
    end
  end

  @doc "Returns all cached engine build directories."
  @spec cached_engine_dirs() :: [String.t()]
  def cached_engine_dirs, do: get_engine_dirs()

  @spec get_engine_dirs() :: [String.t()]
  defp get_engine_dirs do
    base = Forge.Path.expert_cache_dir()

    if File.exists?(base) do
      for expert_ver_dir <- File.ls!(base),
          expert_ver_path = Path.join(base, expert_ver_dir),
          File.dir?(expert_ver_path),
          tool_ver_dir <- File.ls!(expert_ver_path),
          path = Path.join(expert_ver_path, tool_ver_dir),
          File.dir?(path) do
        path
      end
      |> Enum.sort()
    else
      []
    end
  end

  @spec clean_all_force([String.t()]) :: non_neg_integer()
  # Deletes all directories without prompting. Stops on first error and returns 1.
  defp clean_all_force(dirs) do
    result =
      Enum.reduce_while(dirs, :ok, fn dir, _acc ->
        case File.rm_rf(dir) do
          {:ok, _} ->
            IO.puts("Deleted #{dir}")
            {:cont, :ok}

          {:error, reason, file} ->
            IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
            {:halt, :error}
        end
      end)

    case result do
      :ok -> @success_code
      :error -> @error_code
    end
  end

  @spec clean_interactive([String.t()]) :: non_neg_integer()
  # Prompts the user for each directory deletion. Stops on first error and returns 1.
  defp clean_interactive(dirs) do
    result =
      Enum.reduce_while(dirs, :ok, fn dir, _acc ->
        answer = prompt_delete(dir)

        if answer do
          case File.rm_rf(dir) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason, file} ->
              IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
              {:halt, :error}
          end
        else
          {:cont, :ok}
        end
      end)

    case result do
      :ok -> @success_code
      :error -> @error_code
    end
  end

  @spec prompt_delete(dir :: [String.t()]) :: boolean()
  defp prompt_delete(dir) do
    IO.write(["Delete #{dir}? [Yn]"])

    input =
      ""
      |> IO.gets()
      |> String.trim()
      |> String.downcase()

    case input do
      "" -> true
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  @spec print_no_engines_found() :: non_neg_integer()
  defp print_no_engines_found do
    IO.puts("No engine builds found.")
    IO.puts("\nEngine builds are stored in: #{Forge.Path.expert_cache_dir()}")

    @success_code
  end

  @spec print_unknown_subcommand(String.t()) :: non_neg_integer()
  defp print_unknown_subcommand(subcommand) do
    IO.puts(:stderr, """
    Error: Unknown subcommand '#{subcommand}'

    Run 'expert engine --help' for usage information.
    """)

    @error_code
  end

  @spec print_help() :: non_neg_integer()
  defp print_help do
    IO.puts("""
    Expert Engine Management

    Manage cached engine builds. Use these commands to resolve dependency
    errors or free up disk space.

    USAGE:
        expert engine <subcommand>

    SUBCOMMANDS:
        ls              List all engine build directories
        clean           Interactively delete engine build directories

    Use 'expert engine <subcommand> --help' for more information on a specific command.

    EXAMPLES:
        expert engine ls
        expert engine clean
    """)

    @success_code
  end

  @spec print_ls_help() :: non_neg_integer()
  defp print_ls_help do
    IO.puts("""
    List Engine Builds

    List all cached engine build directories.

    USAGE:
        expert engine ls

    EXAMPLES:
        expert engine ls
    """)

    @success_code
  end

  @spec print_clean_help() :: non_neg_integer()
  defp print_clean_help do
    IO.puts("""
    Clean Engine Builds

    Interactively delete cached engine build directories. By default, you will
    be prompted to confirm deletion of each build. Use --force to skip prompts.

    USAGE:
        expert engine clean [options]

    OPTIONS:
        -f, --force     Delete all builds without prompting

    EXAMPLES:
        expert engine clean
        expert engine clean --force
    """)

    @success_code
  end
end
