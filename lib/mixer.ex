defmodule Membrane.Element.LiveAudioMixer do
  @moduledoc """
  An element producing live audio stream by mixing a dynamically changing
  set of input streams.

  When the mixer goes to `:playing` state it sends one interval of silence
  (or more if the `delay` is greater than 0, see the docs for options: `t:t/0`).
  From that moment, after each interval of time the mixer takes the data received from
  upstream elements and produces audio with the duration equal to the interval.

  If some upstream element fails to deliver enough samples for the whole
  interval to be mixed, its data is dropped (including the data that
  comes later but was supposed to be mixed in the current interval).

  If none of the inputs provide enough data, the mixer will generate silence.
  """

  use Bunch
  use Membrane.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter

  alias Membrane.{Buffer, Event, Time}
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Common.AudioMix

  import Mockery.Macro

  alias Membrane.Element.LiveAudioMixer.Timer

  def_options interval: [
                type: :time,
                description: """
                Defines an interval of time between each mix of
                incoming streams. The actual interval used can be rounded up 
                to make sure the number of frames generated for this time period
                is an integer.

                For example, for sample rate 44 100 Hz the interval will be
                rounded to a multiple of 10 ms.

                See the moduledoc (`#{inspect(__MODULE__)}`) for details on how the interval is used.
                """,
                default: 200 |> Time.millisecond()
              ],
              delay: [
                type: :time,
                description: """
                Duration of additional silence sent when mixer goes to `:playing`.

                If the sink consuming from the mixer is live as well, this delay will
                be a difference between the total duration of the produced audio and
                consumed by sink.
                It compensates for the time the buffers need
                to reach the sink after being sent from mixer and prevents 'cracks'
                produced on every interval because of audio samples being late.
                """,
                default: 100 |> Time.millisecond()
              ],
              caps: [
                type: :struct,
                spec: Caps.t(),
                description: """
                The value defines a raw audio format of pads connected to the
                element. It should be the same for all the pads.
                """
              ],
              mute_by_default: [
                type: :boolean,
                description: """
                Determines whether the newly added pads should be muted by default.
                """,
                default: false
              ]

  def_output_pads output: [mode: :push, caps: Caps]
  def_input_pads input: [availability: :on_request, demand_unit: :bytes, caps: Caps]

  @impl true
  def handle_init(%__MODULE__{caps: caps, interval: interval} = options) when interval > 0 do
    second = Time.second(1)
    base = div(second, Integer.gcd(second, caps.sample_rate))
    # An interval has to:
    # - be an integer
    # - correspond to an integer number of frames
    # to make sure there is no rounding when calculating a demand for each interval
    # It is ensured if interval is divisible by base
    interval = trunc(Float.ceil(interval / base)) * base

    state = %{
      caps: options.caps,
      interval: interval,
      delay: options.delay,
      outputs: %{},
      mute_by_default: options.mute_by_default,
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

    state = %{
      state
      | start_playing_time: start_playing_time,
        tick: 1,
        timer_ref: timer_ref
    }

    actions =
      generate_demands(state) ++
        [
          buffer: {:output, %Buffer{payload: silence}}
        ]

    {{:ok, actions}, state}
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
        {pad, %{data | queue: <<>>, skip: 0, mute: state.mute_by_default}}
      end)
      |> Map.new()

    {:ok, %{state | timer_ref: nil, outputs: outputs}}
  end

  @impl true
  def handle_event(pad, %Event.StartOfStream{}, _ctx, state) do
    now_time = mockable(Time).monotonic_time()
    tick_time = now_time |> next_tick_number(state) |> tick_mono_time(state)
    demand = (tick_time - now_time) |> Caps.time_to_bytes(state.caps)

    state =
      state
      |> Bunch.Access.put_in([:outputs, pad], %{
        queue: <<>>,
        eos: false,
        skip: 0,
        mute: state.mute_by_default
      })

    {{:ok, demand: {pad, demand}}, state}
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

    state = %{
      state
      | outputs: outputs,
        tick: next_tick,
        timer_ref: timer_ref
    }

    demands = state |> generate_demands
    actions = [{:buffer, {:output, %Buffer{payload: payload}}} | demands]

    {{:ok, actions}, state}
  end

  def handle_other({:mute, pad_ref}, _ctx, %{outputs: outputs} = state) do
    state =
      if outputs |> Map.has_key?(pad_ref) do
        state |> Bunch.Access.put_in([:outputs, pad_ref, :mute], true)
      else
        warn("Mute error: No such pad #{inspect(pad_ref)}")
        state
      end

    {:ok, state}
  end

  def handle_other({:unmute, pad_ref}, _ctx, %{outputs: outputs} = state) do
    state =
      if outputs |> Map.has_key?(pad_ref) do
        state |> Bunch.Access.put_in([:outputs, pad_ref, :mute], false)
      else
        warn("Unmute error: No such pad #{inspect(pad_ref)}")
        state
      end

    {:ok, state}
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
    |> Enum.reject(fn {_pad, %{mute: mute}} -> mute end)
    |> Enum.map(fn {_pad, %{queue: queue}} -> queue end)
    |> Enum.filter(&(byte_size(&1) == demand))
    ~>> ([] -> [caps |> Caps.sound_of_silence(interval)])
    |> AudioMix.mix_tracks(caps)
  end

  defp update_outputs(outputs, skip_add) do
    outputs
    |> Enum.map(fn {pad, %{queue: queue, skip: skip} = data} ->
      skip = skip + skip_add - byte_size(queue)
      {pad, %{data | queue: <<>>, skip: skip}}
    end)
    |> Enum.filter(fn {_pad, %{eos: eos}} -> not eos end)
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
