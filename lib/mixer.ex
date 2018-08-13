defmodule Membrane.Element.LiveAudioMixer.Source do
  use Membrane.Mixins.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter
  use Membrane.Helper

  alias Membrane.{Buffer, Event}
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Time
  alias Membrane.Common.AudioMix

  def_options interval: [
                type: :integer,
                spec: Time.t(),
                description: """
                The value defines an interval of sending mixed stream to the
                next element. Be aware that if a pad doesn't send enough bytes,
                then all the bytes sent by the pad in the last interval timeframe
                will be discarded. If no pad sends enough bytes, then silence will
                be sent to the next element. The interval is not exact, it's just
                an estimation.
                """,
                default: 1 |> Time.second()
              ],
              delay: [
                type: :integer,
                spec: Time.t(),
                description: """
                The value specifies how much time should we wait before streaming.
                If we don't have any delay then we won't be able to provide
                required amount of bytes on time. This situation can be inappropriate
                for some cases (for example, if we are playing a stream and delay
                is too small then we will hear an unpleasant sound every `interval`
                of time because of the lack of information). On the other
                hand, if delay is too big, we will run out of memory, because we
                will be supposed to store all the information we get from the sinks.
                The first interval of time is filled with silence and is not counted
                as a part of the delay. Delay is also filled with silence.
                """,
                default: 500 |> Time.milliseconds()
              ],
              caps: [
                type: :struct,
                spec: Caps.t(),
                description: """
                The value defines a raw audio format of pads connected to the
                element. It should be the same for all the pads.
                """
              ]

  def_known_source_pads source: {:always, :push, Caps}
  def_known_sink_pads sink: {:on_request, {:pull, demand_in: :bytes}, Caps}

  @impl true
  def handle_init(options) do
    %{
      interval: interval,
      delay: delay,
      caps: caps
    } = options

    state = %{
      interval: interval,
      demand: nil,
      interval_start_time: nil,
      expected_tick_duration: nil,
      lost: 0,
      start: 0,
      ticks: 0,
      sent: 0,

      timer_ref: nil,
      delay: delay,
      caps: caps,
      sinks: %{},
      playing: false
    }

    {:ok, state}
  end

  @impl true
  def handle_play(state) do
    %{
      interval: interval,
      delay: delay,
      caps: caps
    } = state

    interval_start_time = Time.monotonic_time()
    timer_ref = interval |> Helper.Timer.send_after(:tick)
    silence = (interval + delay) |> AudioMix.generate_silence(caps)

    new_state = %{
      state
      | demand: interval |> Caps.time_to_bytes(caps),
        interval_start_time: interval_start_time,
        expected_tick_duration: interval,
        timer_ref: timer_ref,
        playing: true,
        start: interval_start_time,
        ticks: 0
    }

    actions =
      generate_demands(new_state) ++
        [
          buffer: {:source, %Buffer{payload: silence}}
        ]

    {{:ok, actions}, new_state}
  end

  @impl true
  def handle_prepare(:playing, state) do
    %{
      timer_ref: timer_ref,
      sinks: sinks
    } = state

    # TODO: When Helper.Timer is updated, this line of code should be changed
    timer_ref |> :timer.cancel()

    sinks =
      sinks
      |> Enum.map(fn {pad, %{eos: eos}} ->
        {pad, %{queue: <<>>, eos: eos}}
      end)
      |> Map.new()

    {:ok, %{state | playing: false, timer_ref: nil, sinks: sinks}}
  end

  def handle_prepare(_previous_playback_state, state), do: {:ok, state}

  @impl true
  def handle_pad_removed(pad, _context, state) do
    state = state |> Helper.Map.update_in([:sinks, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event{type: :sos}, _context, state) do
    %{
      demand: demand,
      playing: playing
    } = state

    actions =
      if playing == true do
        [demand: {pad, :self, {:set_to, demand}}]
      else
        []
      end

    state = state |> Helper.Map.put_in([:sinks, pad], %{queue: <<>>, eos: false})
    {{:ok, actions}, state}
  end

  def handle_event(pad, %Event{type: :eos} = event, _context, state) do
    state = state |> Helper.Map.update_in([:sinks, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  def handle_event(_pad, _event, _context, state) do
    {:ok, state}
  end

  @impl true
  def handle_process1(pad, buffer, _context, state) do
    %Buffer{payload: payload} = buffer

    state =
      state
      |> Helper.Map.update_in([:sinks, pad], fn %{queue: queue, eos: eos} ->
        %{queue: queue <> payload, eos: eos}
      end)

    {:ok, state}
  end

  @impl true
  def handle_other(:tick, %{playing: true} = state) do
    IO.puts("TICK")
    IO.puts("TICKS: #{state.ticks + 1}")
    IO.puts("EXPECTED TICKS: #{(Time.monotonic_time() - state.start) / state.interval}")
    IO.puts("SENT: #{state.sent / state.demand}")
    IO.puts("LOST: #{state.lost}")
    %{
      interval: interval,
      demand: demand,
      interval_start_time: interval_start_time,
      expected_tick_duration: expected_tick_duration,
      caps: caps,
      sinks: sinks
    } = state

    now_time = Time.monotonic_time()
    tick_duration = now_time - interval_start_time
    time_diff = tick_duration - expected_tick_duration
    new_expected_tick_duration = interval - time_diff

    timer_ref = new_expected_tick_duration |> Helper.Timer.send_after(:tick)

    IO.puts(tick_duration)

    payloads =
      sinks
      |> Enum.map(fn {_pad, %{queue: queue}} ->
        if byte_size(queue) == demand do
          IO.puts("NIE DUPSKO")
          queue
        else
          IO.puts("DUPSKO: #{byte_size(queue)}")
          <<>>
        end
      end)
      |> Enum.filter(&(byte_size(&1) > 0))

    lost =
      if payloads == [] do
        state.lost + 1
      else
        state.lost
      end

    payloads =
      if payloads == [] do
        [interval |> AudioMix.generate_silence(caps)]
      else
        payloads
      end
    payload = AudioMix.mix(payloads, caps)

    sinks =
      state.sinks
      |> Enum.map(fn {pad, %{eos: eos}} ->
        {pad, %{queue: <<>>, eos: eos}}
      end)
      |> Enum.filter(fn {_pad, %{eos: eos}} ->
        eos == false
      end)
      |> Map.new()

    new_state = %{
      state
      | sinks: sinks,
        expected_tick_duration: new_expected_tick_duration,
        demand: interval |> Caps.time_to_bytes(caps),
        interval_start_time: now_time,
        timer_ref: timer_ref,
        lost: lost,
        ticks: state.ticks + 1,
        sent: state.sent + byte_size(payload)
    }

    demands = new_state |> generate_demands
    actions = demands ++ [buffer: {:source, %Buffer{payload: payload}}]

    {{:ok, actions}, new_state}
  end

  def handle_other(_message, state), do: {:ok, state}

  defp generate_demands(state) do
    %{
      demand: demand,
      sinks: sinks
    } = state

    sinks
    |> Enum.map(fn {pad, _} ->
      {:demand, {pad, :self, {:set_to, demand}}}
    end)
  end
end
