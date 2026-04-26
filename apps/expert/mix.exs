defmodule Expert.MixProject do
  use Mix.Project

  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :expert,
      version: version(),
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: Mix.Dialyzer.config(add_apps: [:jason]),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      default_release: :expert
    ]
  end

  def version do
    "../../version.txt" |> File.read!() |> String.trim()
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :kernel, :wx, :observer, :telemetry],
      mod: {Expert.Application, []}
    ]
  end

  def aliases do
    [
      compile: "compile --docs --debug-info",
      docs: "docs --html",
      test: "test --no-start"
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  defp releases do
    [
      expert: [
        strip_beams: false,
        cookie: "expert",
        steps: release_steps() ++ [&Burrito.wrap/1],
        burrito: [
          targets: [
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            darwin_amd64: [os: :darwin, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_amd64: [os: :linux, cpu: :x86_64],
            windows_amd64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ],
      plain: [
        strip_beams: false,
        cookie: "expert",
        steps: release_steps() ++ [&Expert.Release.plain_assemble/1],
        include_executables_for: executables(),
        overlays: overlays()
      ]
    ]
  end

  defp release_steps do
    [
      :assemble,
      &Expert.Release.assemble/1
    ]
  end

  defp executables do
    if windows?(), do: [:windows], else: [:unix]
  end

  defp overlays do
    if windows?(), do: ["rel/windows"], else: ["rel/unix"]
  end

  defp windows? do
    :os.type() |> elem(0) == :win32
  end

  defp deps do
    [
      {:burrito, "~> 1.5"},
      {:deps_nix, "~> 2.4", only: :dev},
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      # In practice Expert does not hardly depend on Engine, only on its compiled
      # artifacts, but we need it as a test dependency to set up tests that
      # assume a roundtrip to a project node is made.
      {:engine, path: "../engine", only: [:test]},
      {:forge, path: "../forge"},
      {:gen_lsp, "~> 0.11.3"},
      {:jason, "~> 1.4"},
      {:patch, "~> 0.15", runtime: false, only: [:dev, :test]},
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false},
      {:path_glob, "~> 0.2"},
      {:phoenix_live_view, "~> 1.0", only: [:test], runtime: false},
      {:schematic, "~> 0.2"},
      {:sourceror, "~> 1.10.1"}
    ]
  end
end
