defmodule Expert.Release do
  def assemble(release) do
    # In-place namespacing: both source and output are the same path
    Mix.Task.run(:namespace, [release.path, release.path])

    expert_root = Path.expand("../../../..", __DIR__)
    engine_path = Path.join([expert_root, "apps", "engine"])
    forge_path = Path.join([expert_root, "apps", "forge"])

    engine_sources =
      [
        "lib",
        "deps",
        "mix.exs",
        "config",
        "mix.lock"
      ]
      |> Enum.map(&Path.join([engine_path, &1]))

    forge_sources =
      [
        "lib",
        "src",
        "mix.exs",
        "config",
        "mix.lock"
      ]
      |> Enum.map(&Path.join([forge_path, &1]))

    root_exs = Path.join([expert_root, "*.exs"])
    version_file = Path.join([expert_root, "version.txt"])

    dest =
      Path.join([
        release.path,
        "lib",
        "xp_expert-#{release.version}",
        "priv",
        "engine_source"
      ])

    for source <- engine_sources do
      dest_path = Path.join([dest, "apps", "engine", Path.basename(source)])
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp_r!(source, dest_path)
    end

    for source <- forge_sources do
      dest_path = Path.join([dest, "apps", "forge", Path.basename(source)])
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp_r!(source, dest_path)
    end

    File.rm_rf!(Path.join([dest, "apps", "forge", "lib", "test"]))

    for exs_file <- Path.wildcard(root_exs) do
      dest_path = Path.join([dest, Path.basename(exs_file)])
      File.cp_r!(exs_file, dest_path)
    end

    File.cp!(version_file, Path.join([dest, "version.txt"]))

    release
  end

  def plain_assemble(release) do
    executable = if windows?(), do: "start_expert.bat", else: "start_expert"
    executable_path = Path.join([release.path, "bin", executable])

    # Make the executable script runnable
    File.chmod!(executable_path, 0o755)

    if release.options[:quiet] do
      release
    else
      Mix.shell().info("""

      #{IO.ANSI.bright()}✨ Expert build created at:#{IO.ANSI.reset()} #{release.path}

      To use it, point your editor LSP configuration to:

          #{executable_path} --stdio

      You can also run Expert in TCP mode by passing the `--port PORT` argument:

          #{executable_path} --port 9000

      To get a list of all available command line options, run:

          #{executable_path} --help
      """)

      # Silence the release "announce" message
      new_opts = Keyword.put(release.options, :quiet, true)
      %{release | options: new_opts}
    end
  end

  def windows? do
    :os.type() |> elem(0) == :win32
  end
end
