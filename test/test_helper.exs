ExUnit.start()

defmodule TimerMock do
  @enforce_keys [:tiemr_ref]
  defstruct [:timer_ref]

  def send_after(time, msg, dest \\ self(), opts \\ []) do
    send(self(), {:send_after, time, msg, dest, opts})
    :timer_ref
  end

  def cancel_timer(timer_ref, options \\ []) do
    send(self(), {:cancel_timer, timer_ref, options})
    :ok
  end
end
