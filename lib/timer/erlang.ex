defmodule Membrane.Element.LiveAudioMixer.Timer.Erlang do
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
    timeout = interval |> Time.to_milliseconds()
    {:ok, state, timeout}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, target, _reason}, %{target: target} = state) do
    {:stop, :shutdown, state}
  end

  def handle_info(:timeout, %{target: target} = state) do
    tick_cnt = state.tick_cnt + 1
    next_tick_time = state.start_time + tick_cnt * state.interval
    send(target, {:tick, next_tick_time})
    state = %{state | tick_cnt: tick_cnt}
    {:noreply, state, next_tick_time - current_time()}
  end
end
