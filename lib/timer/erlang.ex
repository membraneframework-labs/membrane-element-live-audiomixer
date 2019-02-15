defmodule Membrane.Element.LiveAudioMixer.Timer.Erlang do
  @moduledoc """
  Timer based on Erlang VM monotonic time
  """
  use GenServer

  alias Membrane.Element.LiveAudioMixer.Timer
  alias Membrane.Time

  @behaviour Timer

  @impl Timer
  def start_sender(target, interval, delay) do
    GenServer.start(__MODULE__, [target, interval, delay])
  end

  @impl Timer
  def stop_sender(timer_ref) do
    GenServer.stop(timer_ref)
  end

  @impl Timer
  def current_time() do
    Time.monotonic_time()
  end

  @impl GenServer
  def init([target, interval, delay]) do
    state = %{
      target: target,
      interval: interval,
      delay: delay,
      timer_ref: nil,
      tick_cnt: 1,
      start_time: current_time()
    }

    Process.monitor(target)
    send_after_time = interval |> Time.to_milliseconds()
    Process.send_after(self(), :send_tick, send_after_time)
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, target, _reason}, %{target: target} = state) do
    {:stop, :shutdown, state}
  end

  def handle_info(:send_tick, %{target: target} = state) do
    tick_cnt = state.tick_cnt + 1
    next_tick_time = state.start_time + tick_cnt * state.interval
    send(target, {:tick, next_tick_time})

    state = %{state | tick_cnt: tick_cnt}

    send_after_time = (next_tick_time - current_time()) |> max(0) |> Time.to_milliseconds()
    Process.send_after(self(), :send_tick, send_after_time)

    {:noreply, state}
  end
end
