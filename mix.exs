defmodule Acari.MixProject do
  use Mix.Project

  def project do
    [
      app: :acari,
      version: "1.0.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.0"},
      {:tunctl, git: "https://github.com/ileamo/tunctl.git"},
      {:jason, "~> 1.0"}
    ]
  end
end
