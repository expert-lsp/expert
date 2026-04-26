defmodule Forge.MixProject do
  use Mix.Project

  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :forge,
      version: version(),
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:yecc] ++ Mix.compilers(),
      dialyzer: Mix.Dialyzer.config(),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures")]
    ]
  end

  def version do
    "../../version.txt" |> File.read!() |> String.trim()
  end

  def application do
    [
      extra_applications: [:logger, :sasl, :eex]
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  defp deps do
    [
      {:benchee, "~> 1.3", only: :test},
      {:briefly, "~> 0.5"},
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      {:deps_nix, "~> 2.4", only: :dev},
      {:gen_lsp, "~> 0.11.3"},
      {:sourceror, "~> 1.10.1"},
      {:spitfire, github: "Draggu/spitfire", branch: "expose-expand"},
      {:stream_data, "~> 1.1", only: [:test], runtime: false},
      {:patch, "~> 0.15", only: [:test], optional: true, runtime: false},
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false}
    ]
  end
end
