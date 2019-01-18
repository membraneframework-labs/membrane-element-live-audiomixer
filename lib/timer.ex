defmodule Membrane.Element.LiveAudioMixer.Timer do
  @moduledoc false

  alias Membrane.Time

  def send_after(time, msg, opts \\ []) do
    Process.send_after(self(), msg, time |> Time.to_milliseconds(), opts)
  end

  def cancel_timer(timer_ref, options \\ []) do
    Process.cancel_timer(timer_ref, options)
  end
end
