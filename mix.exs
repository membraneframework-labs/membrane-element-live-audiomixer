defmodule Membrane.Element.LiveAudioMixer.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_element_live_audiomixer,
      version: "0.1.0",
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.19"},
      {:membrane_core, "~> 0.2.0", github: "membraneframework/membrane-core", override: true},
      {:membrane_caps_audio_raw, "~> 0.1.3"},
      {:membrane_loggers, "~> 0.2"},
      {:membrane_common_audiomix, github: "membraneframework/membrane-common-audiomix"},
      {:bunch, "~> 0.1.2"},
      {:mockery, "~> 2.2.0", runtime: false}
    ]
  end
end
