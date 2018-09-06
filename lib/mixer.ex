defmodule Membrane.Element.LiveAudioMixer.Source do
  use Membrane.Mixins.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter

  alias Membrane.{Buffer, Event, Helper, Time}
  alias Membrane.Caps.Audio.Raw, as: Caps
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

  @timer Application.get_env(:membrane_element_live_audiomixer, :mixer_timer)

  @impl true
  def handle_init(options) do
    %{
      interval: interval,
      delay: delay,
      caps: caps
    } = options

    state = %{
      interval: interval,
      delay: delay,
      caps: caps,
      sinks: %{},
      interval_start_time: nil,
      expected_tick_duration: nil,
      timer_ref: nil,
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
    timer_ref = interval |> @timer.send_after(:tick)
    silence = (interval + delay) |> AudioMix.generate_silence(caps)

    new_state = %{
      state
      | interval_start_time: interval_start_time,
        expected_tick_duration: interval,
        timer_ref: timer_ref,
        playing: true
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

    timer_ref |> @timer.cancel_timer()

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
    actions =
      if state.playing == true do
        [demand: {pad, :self, {:set_to, get_demand(state)}}]
      else
        []
      end

    state = state |> Helper.Map.put_in([:sinks, pad], %{queue: <<>>, eos: false})
    {{:ok, actions}, state}
  end

  def handle_event(pad, %Event{type: :eos}, _context, state) do
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
    %{
      interval: interval,
      interval_start_time: interval_start_time,
      expected_tick_duration: expected_tick_duration,
      caps: caps,
      sinks: sinks
    } = state

    demand = get_demand(state)

    now_time = Time.monotonic_time()
    tick_duration = now_time - interval_start_time
    time_diff = tick_duration - expected_tick_duration
    new_expected_tick_duration = interval - time_diff

    timer_ref = new_expected_tick_duration |> @timer.send_after(:tick)

    payloads =
      sinks
      |> Enum.map(fn {_pad, %{queue: queue}} ->
        if byte_size(queue) == demand do
          queue
        else
          <<>>
        end
      end)
      |> Enum.filter(&(byte_size(&1) > 0))

    payloads =
      if payloads == [] do
        [interval |> AudioMix.generate_silence(caps)]
      else
        payloads
      end

    payload = payloads |> AudioMix.mix(caps)

    sinks =
      sinks
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
        interval_start_time: now_time,
        timer_ref: timer_ref
    }

    demands = new_state |> generate_demands
    actions = demands ++ [buffer: {:source, %Buffer{payload: payload}}]

    {{:ok, actions}, new_state}
  end

  def handle_other(_message, state), do: {:ok, state}

  defp generate_demands(state) do
    demand = get_demand(state)

    state.sinks
    |> Enum.map(fn {pad, _} ->
      {:demand, {pad, :self, {:set_to, demand}}}
    end)
  end

  defp get_demand(state) do
    %{
      interval: interval,
      caps: caps
    } = state

    interval |> Caps.time_to_bytes(caps)
  end
end
