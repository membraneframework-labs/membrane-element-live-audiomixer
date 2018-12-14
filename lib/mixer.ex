defmodule Membrane.Element.LiveAudioMixer do
  @moduledoc """
  An element producing live audio stream by mixing a dynamically changing
  set of input streams.

  When the mixer goes to `:playing` state it sends one interval of silence
  (or more if the `delay` is greater than 0, see the docs for options: `t:t/0`).
  From that moment, after each interval of time the mixer takes the data received from
  upstream elements and produces audio with the duration equal to the interval.

  If some upstream element fails to deliver enough samples for the whole
  interval to be mixed, its data will be dropped (including the data that
  comes later but was supposed to be mixed in the current interval).

  If none of the inputs provide enough data, the mixer will generate silence.
  """

  # FIXME: it's possible that because of rounding errors we will send too much data
  # each `interval` of time (hello, `interval |> Caps.time_to_bytes(caps)`). It
  # should be fixed.

  use Bunch
  use Membrane.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter

  alias Membrane.{Buffer, Event, Time}
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Common.AudioMix

  import Mockery.Macro

  alias Membrane.Element.LiveAudioMixer.Timer

  def_options interval: [
                type: :integer,
                spec: Time.t(),
                description: """
                Defines an interval of time (in milliseconds) between each mix of incoming streams.
                See the moduledoc (`#{inspect(__MODULE__)}`) for more info.
                """,
                default: 200
              ],
              delay: [
                type: :integer,
                spec: Time.t(),
                description: """
                Duration (in milliseconds) of additional silence sent when mixer goes to `:playing`.

                If the sink consuming from the mixer is live as well, this delay will
                be a difference between the total duration of the produced audio and
                consumed by sink.
                It compensates for the time the buffers need
                to reach the sink after being sent from mixer and prevents 'cracks'
                produced on every interval because of audio samples being late.
                """,
                default: 100
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
    state = %{
      caps: options.caps,
      interval: Time.millisecond(options.interval),
      delay: Time.millisecond(options.delay),
      outputs: %{},
      start_playing_time: nil,
      tick: 1,
      timer_ref: nil
    }

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
    timer_ref = interval |> mockable(Timer).send_after(:tick)

    new_state = %{
      state
      | start_playing_time: start_playing_time,
        tick: 1,
        timer_ref: timer_ref
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

    timer_ref |> mockable(Timer).cancel_timer()

    outputs =
      outputs
      |> Enum.map(fn {pad, data} ->
        {pad, %{data | queue: <<>>, skip: 0}}
      end)
      |> Map.new()

    {:ok, %{state | timer_ref: nil, outputs: outputs}}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    state =
      if state |> Bunch.Access.get_in([:outputs, pad]) != nil do
        state |> Bunch.Access.put_in([:outputs, pad, :eos], true)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event.StartOfStream{}, ctx, state) do
    now_time = mockable(Time).monotonic_time()
    tick_time = now_time |> next_tick_number(state) |> tick_mono_time(state)
    demand = (tick_time - now_time) |> Caps.time_to_bytes(state.caps)

    actions =
      if ctx.playback_state == :playing do
        [demand: {pad, demand}]
      else
        []
      end

    state = state |> Bunch.Access.put_in([:outputs, pad], %{queue: <<>>, eos: false, skip: 0})
    {{:ok, actions}, state}
  end

  def handle_event(pad, %Event.EndOfStream{}, _context, state) do
    state = state |> Bunch.Access.put_in([:outputs, pad, :eos], true)
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
  def handle_other(:tick, %{playback_state: :playing}, state) do
    %{
      tick: tick,
      outputs: outputs
    } = state

    payload = state |> mix_tracks

    now_time = mockable(Time).monotonic_time()
    next_tick = next_tick_number(now_time, state)
    timer_ref = (tick_mono_time(next_tick, state) - now_time) |> mockable(Timer).send_after(:tick)

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

  def handle_other(_message, _ctx, state), do: {:ok, state}

  defp mix_tracks(state) do
    %{
      interval: interval,
      caps: caps,
      outputs: outputs
    } = state

    demand = state |> get_default_demand

    outputs
    |> Enum.map(fn {_pad, %{queue: queue}} ->
      if byte_size(queue) == demand do
        queue
      else
        <<>>
      end
    end)
    |> Enum.filter(&(byte_size(&1) > 0))
    ~>> ([] -> [caps |> Caps.sound_of_silence(interval)])
    |> AudioMix.mix_tracks(caps)
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

  defp get_default_demand(%{interval: interval, caps: caps}) do
    interval |> Caps.time_to_bytes(caps)
  end

  defp next_tick_number(time, state) do
    %{
      interval: interval,
      start_playing_time: start_playing_time
    } = state

    div(time - start_playing_time, interval) + 1
  end

  defp tick_mono_time(tick, state) do
    %{
      interval: interval,
      start_playing_time: start_playing_time
    } = state

    start_playing_time + tick * interval
  end
end
