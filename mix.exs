defmodule XP.MixProject do
  use Mix.Project

  def project do
    [
      app: :xp,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp deps do
    []
  end
end
