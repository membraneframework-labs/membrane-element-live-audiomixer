defmodule Membrane.Element.LiveAudioMixer.Source do
  @moduledoc """
  The module is used for mixing several streams from different sources.
  Sources can be dynamically added and removed, it's ok. It listens to
  the sources for `interval` of time and mixes received data after that.
  If some of the sources don't provide enough data, that data will be discarded.
  If none of the sources provides enough data, silence will be generated.

  FIXME: it's possible that because of rounding errors we will send too much data
  each `interval` of time (hello, `interval |> Caps.time_to_bytes(caps)``). It
  should be fixed.
  """

  use Membrane.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter

  alias Membrane.{Buffer, Event, Time}
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Common.AudioMix

  import Mockery.Macro

  @timer Application.get_env(
           :membrane_element_live_audiomixer,
           :mixer_timer,
           Membrane.Element.LiveAudioMixer.Timer
         )

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

  def_output_pads output: [mode: :push, caps: Caps]
  def_input_pads input: [availability: :on_request, mode: :pull, demand_unit: :bytes, caps: Caps]

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        outputs: %{},
        start_playing_time: nil,
        tick: 1,
        timer_ref: nil,
        playing: false
      })

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    %{
      interval: interval,
      delay: delay,
      caps: caps
    } = state

    silence = caps |> Caps.sound_of_silence(interval + delay)
    start_playing_time = mockable(Time).monotonic_time()
    timer_ref = interval |> @timer.send_after(:tick)

    new_state = %{
      state
      | start_playing_time: start_playing_time,
        tick: 1,
        timer_ref: timer_ref,
        playing: true
    }

    actions =
      generate_demands(new_state) ++
        [
          buffer: {:output, %Buffer{payload: silence}}
        ]

    {{:ok, actions}, new_state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    %{
      timer_ref: timer_ref,
      outputs: outputs
    } = state

    timer_ref |> @timer.cancel_timer()

    outputs =
      outputs
      |> Enum.map(fn {pad, data} ->
        {pad, %{data | queue: <<>>, skip: 0}}
      end)
      |> Map.new()

    {:ok, %{state | playing: false, timer_ref: nil, outputs: outputs}}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    state =
      if state |> Bunch.Access.get_in([:outputs, pad]) != nil do
        state |> Bunch.Access.update_in([:outputs, pad], &%{&1 | eos: true})
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event.StartOfStream{}, _context, state) do
    now_time = mockable(Time).monotonic_time()
    tick_time = now_time |> get_next_tick(state) |> get_tick_time(state)
    demand = (tick_time - now_time) |> Caps.time_to_bytes(state.caps)

    actions =
      if state.playing == true do
        [demand: {pad, demand}]
      else
        []
      end

    state = state |> Bunch.Access.put_in([:outputs, pad], %{queue: <<>>, eos: false, skip: 0})
    {{:ok, actions}, state}
  end

  def handle_event(pad, %Event.EndOfStream{}, _context, state) do
    state = state |> Bunch.Access.update_in([:outputs, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  def handle_event(_pad, _event, _context, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(pad, buffer, _context, state) do
    %Buffer{payload: payload} = buffer

    state =
      state
      |> Bunch.Access.update_in([:outputs, pad], fn %{queue: queue, skip: skip} = data ->
        to_skip = min(skip, payload |> byte_size)
        <<_skipped::binary-size(to_skip), payload::binary>> = payload
        %{data | queue: queue <> payload, skip: skip - to_skip}
      end)

    {:ok, state}
  end

  @impl true
  def handle_other(:tick, _ctx, %{playing: true} = state) do
    %{
      tick: tick,
      outputs: outputs
    } = state

    payload = state |> mix_streams

    now_time = mockable(Time).monotonic_time()
    next_tick = get_next_tick(now_time, state)
    timer_ref = (get_tick_time(next_tick, state) - now_time) |> @timer.send_after(:tick)

    demand = state |> get_default_demand
    outputs = outputs |> update_outputs(demand * (next_tick - tick))

    new_state = %{
      state
      | outputs: outputs,
        tick: next_tick,
        timer_ref: timer_ref
    }

    demands = new_state |> generate_demands
    actions = [{:buffer, {:output, %Buffer{payload: payload}}} | demands]

    {{:ok, actions}, new_state}
  end

  def handle_other(_message, state), do: {:ok, state}

  defp mix_streams(state) do
    %{
      interval: interval,
      caps: caps,
      outputs: outputs
    } = state

    demand = state |> get_default_demand

    streams =
      outputs
      |> Enum.map(fn {_pad, %{queue: queue}} ->
        if byte_size(queue) == demand do
          queue
        else
          <<>>
        end
      end)
      |> Enum.filter(&(byte_size(&1) > 0))

    if streams == [] do
      [caps |> Caps.sound_of_silence(interval)]
    else
      streams
    end
    |> AudioMix.mix_streams(caps)
  end

  defp update_outputs(outputs, skip_add) do
    outputs
    |> Enum.map(fn {pad, %{queue: queue, skip: skip} = data} ->
      skip = skip + skip_add - byte_size(queue)
      {pad, %{data | queue: <<>>, skip: skip}}
    end)
    |> Enum.filter(fn {_pad, %{eos: eos}} ->
      eos == false
    end)
    |> Map.new()
  end

  defp generate_demands(state) do
    demand = get_default_demand(state)

    state.outputs
    |> Enum.map(fn {pad, %{skip: skip}} ->
      {:demand, {pad, demand + skip}}
    end)
  end

  defp get_default_demand(state) do
    %{
      interval: interval,
      caps: caps
    } = state

    interval |> Caps.time_to_bytes(caps)
  end

  defp get_next_tick(time, state) do
    %{
      interval: interval,
      start_playing_time: start_playing_time
    } = state

    div(time - start_playing_time, interval) + 1
  end

  defp get_tick_time(tick, state) do
    %{
      interval: interval,
      start_playing_time: start_playing_time
    } = state

    start_playing_time + tick * interval
  end
end
