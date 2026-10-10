defmodule ExpertHEEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :expert_heex,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", Path.expand("../test_support", __DIR__)]
  defp elixirc_paths(_env), do: ["lib"]
end
