defmodule Acari.MixProject do
  use Mix.Project

  def project do
    [
      app: :acari,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Acari.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tunctl, git: "https://github.com/msantos/tunctl.git"},
      {:poison, "~> 4.0.1"},
      {:distillery, "~> 2.0"}
    ]
  end
end
