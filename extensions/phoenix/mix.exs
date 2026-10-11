defmodule ExpertPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :expert_phoenix,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", Path.expand("../test_support", __DIR__)]
  defp elixirc_paths(_env), do: ["lib"]
end
