defmodule Membrane.Element.LiveAudioMixer.Timer.LibShout do
  @moduledoc """
  Timer imitiating one used by libshout for synchronization

  It gets time by calling `gettimeofday` and rounding the result to milliseconds.
  For waiting uses `select` system call (compared to nanosleep uses microseconds
  instead of nanoseconds and cannot be interrupted by a signal)
  """
  use GenServer
  use Unifex.Loader
  alias Membrane.Element.LiveAudioMixer.Timer
  alias Membrane.Time

  @behaviour Timer

  @impl Timer
  def start_sender(target, interval, delay) do
    GenServer.start(__MODULE__, [target, interval, delay])
  end

  @impl Timer
  def stop_sender(timer_ref) do
    # Async stop
    GenServer.cast(timer_ref, :stop)
  end

  @impl Timer
  def current_time() do
    native_time() |> Time.milliseconds()
  end

  @impl GenServer
  def init([target, interval, delay]) do
    with interval = interval |> Time.to_milliseconds(),
         delay = delay |> Time.to_milliseconds(),
         {:ok, timer_ref} <- start_native_sender(target, interval, delay) do
      state = %{timer_ref: timer_ref}

      Process.monitor(target)
      {:ok, state, :hibernate}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _object, _reason}, %{timer_ref: timer_ref} = state) do
    stop_native_sender(timer_ref)
    {:stop, :shutdown, %{state | timer_ref: nil}}
  end

  @impl GenServer
  def handle_cast(:stop, %{timer_ref: timer_ref} = state) do
    stop_native_sender(timer_ref)
    {:stop, :normal, %{state | timer_ref: nil}}
  end
end
