defmodule Smell.MixProject do
  use Mix.Project

  def project do
    [
      app: :smell,
      version: "0.1.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      files: [
        ".credo.exs",
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      licenses: ["MIT"],
      description:
        "Collection of Elixir checks to identify common code smells for enhanced code quality.",
      maintainers: ["Ricardo Santos"],
      links: %{
        "GitHub" => "https://github.com/RicardoSantos-99/smell.git"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false}
    ]
  end
end
