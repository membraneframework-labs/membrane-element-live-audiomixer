defmodule Membrane.Element.LiveAudioMixer.App do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = []

    opts = [strategy: :one_to_one, name: Membrane.Element.LiveAudioMixer.App]
    Supervisor.start_link(children, opts)
  end
end
