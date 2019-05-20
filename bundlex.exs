defmodule Membrane.Element.LiveAudioMixer.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      nifs: nifs(Bundlex.platform())
    ]
  end

  def nifs(_platform) do
    [
      timer: [
        deps: [unifex: :unifex],
        sources: ["_generated/timer.c", "timer.c"]
      ]
    ]
  end
end
