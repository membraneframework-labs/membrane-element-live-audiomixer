defmodule Membrane.Element.LiveAudioMixer.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_element_live_audiomixer,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      mixer_timer: Membrane.Element.LiveAudioMixer.Timer
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 0.1"},
      {:membrane_caps_audio_raw, "~> 0.1"},
      {:membrane_loggers, "~> 0.1"},
      {:membrane_common_audiomix,
       path: "/Users/vladyslav/Documents/repos/membrane_common_audiomix"}
    ]
  end
end
