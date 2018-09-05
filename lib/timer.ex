defmodule Membrane.Element.LiveAudioMixer.Timer do
  alias Membrane.Time

  def send_after(time, msg, dest \\ self(), opts \\ []) do
    Process.send_after(dest, msg, time |> Time.to_milliseconds(), opts)
  end

  def cancel_timer(timer_ref, options \\ []) do
    Process.cancel_timer(timer_ref, options)
  end
end
