defmodule Engine.MixProject do
  use Mix.Project

  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :engine,
      version: version(),
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: Mix.Dialyzer.config(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      preferred_cli_env: [benchmark: :test]
    ]
  end

  def version do
    "../../version.txt" |> File.read!() |> String.trim()
  end

  def application do
    [
      extra_applications: [:logger, :sasl, :eex, :path_glob],
      mod: {Engine.Application, []}
    ]
  end

  # cli/0 is new for elixir 1.15, prior, we need to set `preferred_cli_env` in the project
  def cli do
    [
      preferred_envs: [benchmark: :test]
    ]
  end

  defp elixirc_paths(:test) do
    ~w(lib test/support)
  end

  defp elixirc_paths(_) do
    ~w(lib)
  end

  defp deps do
    [
      {:deps_nix, "~> 3.0", only: :dev},
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      {:elixir_sense,
       github: "elixir-lsp/elixir_sense", ref: "da065ae9ccc125d05b901b9eb6981ff559a8f9f1"},
      {:forge, path: "../forge"},
      {:gen_lsp, "~> 0.11.4"},
      {:logger_backends, "~> 1.0"},
      {:patch, "~> 0.15", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false},
      {:path_glob, "~> 0.2"},
      {:phoenix_live_view, "~> 1.0", only: [:test], runtime: false},
      {:sourceror, "~> 1.12.2"},
      {:stream_data, "~> 1.1", only: [:test], runtime: false},
      # Offline engine builds cannot depend on a local Rebar archive, so we
      # force it to Mix
      {:telemetry, "~> 1.3", manager: :mix, optional: false, override: true}
    ]
  end

  defp aliases do
    [test: "test --no-start", benchmark: "run"]
  end
end
