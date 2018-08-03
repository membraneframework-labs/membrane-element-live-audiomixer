defmodule Membrane.Element.LiveAudioMixer do
  use Application

  def start(_type, _args) do
    children = []

    opts = [strategy: :one_to_one, name: Membrane.Element.LiveAudioMixer]
    Supervisor.start_link(children, opts)
  end
end
