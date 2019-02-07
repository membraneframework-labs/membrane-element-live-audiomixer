defmodule Membrane.Element.LiveAudioMixer.Timer do
  @moduledoc """
  A behaviour for a timer that can be used by the mixer.
  """
  alias Membrane.Time

  @type t :: reference() | pid()

  @type tick_t :: {:tick, next_tick_time :: Time.t()}

  @doc """
  Start a sender, that will periodically send a `t:tick_t/0` message to the target
  """
  @callback start_sender(
              target :: pid(),
              interval :: Time.t(),
              delay :: Time.t()
            ) ::
              {:ok, t} | {:error, any()}

  @doc """
  Stops a sender
  """
  @callback stop_sender(t) :: :ok | {:error, any()}

  @doc """
  Returns current time
  """
  @callback current_time() :: Time.t()
end
