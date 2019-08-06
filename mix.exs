defmodule Membrane.Element.LiveAudioMixer.MixProject do
  use Mix.Project

  @version "0.1.1"
  @github_url "https://github.com/membraneframework/membrane-element-live-audiomixer"

  def project do
    [
      app: :membrane_element_live_audiomixer,
      compilers: [:unifex, :bundlex] ++ Mix.compilers(),
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      name: "Membrane Element: Live AudioMixer",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membraneframework.org",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Element, Membrane.Element.LiveAudioMixer]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:membrane_core,
       github: "membraneframework/membrane-core", branch: "master", override: true},
      {:membrane_caps_audio_raw, "~> 0.1.7"},
      {:membrane_loggers, "~> 0.2.0"},
      {:membrane_common_audiomix, github: "membraneframework/membrane-common-audiomix"},
      {:bunch, "~> 1.0"},
      {:unifex, "~> 0.2"}
    ]
  end
end
