defmodule Membrane.Element.LiveAudioMixer.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_element_live_audiomixer,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:membrane_core,
       git: "git@github.com:membraneframework/membrane-core.git",
       branch: "fix/dynamic_pads",
       override: true},
      {:membrane_caps_audio_raw,
       path: "/Users/vladyslav/Documents/repos/membrane-caps-audio-raw", override: true},
      {:membrane_loggers, "~> 0.1"},
      {:membrane_common_audiomix,
       path: "/Users/vladyslav/Documents/repos/membrane_common_audiomix"},
      {:mockery, "~> 2.2.0", runtime: false}
    ]
  end
end
