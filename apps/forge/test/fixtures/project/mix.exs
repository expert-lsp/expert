defmodule Project.MixProject do
  use Mix.Project

  def project do
    Code.put_compiler_option(:ignore_module_conflict, true)

    [
      app: :project,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :erts]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sourceror, "~> 1.13"}
    ]
  end
end
