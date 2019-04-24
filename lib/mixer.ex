defmodule Membrane.Element.LiveAudioMixer do
  @moduledoc """
  An element producing live audio stream by mixing a dynamically changing
  set of input streams.

  When the mixer goes to `:playing` state it sends some silence
  (configured by `out_delay` see the [docs for options](#module-element-options)).
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

  alias Membrane.Element.LiveAudioMixer.Timer

  @default_mute_val false

  def_options interval: [
                type: :time,
                description: """
                Defines an interval of time between each mix of
                incoming streams. The actual interval used might be rounded up
                to make sure the number of frames generated for this time period
                is an integer.

                For example, for sample rate 44 100 Hz the interval will be
                rounded to a multiple of 10 ms.

                See the moduledoc (`#{inspect(__MODULE__)}`) for details on how the interval is used.
                """,
                default: 500 |> Time.millisecond()
              ],
              in_delay: [
                type: :time,
                description: """
                A delay before the input streams are mixed for the first time.
                """,
                default: 200 |> Time.millisecond()
              ],
              out_delay: [
                type: :time,
                description: """
                Duration of additional silence sent before first buffer with mixed audio.

                Effectively delays the mixed output stream: this delay will
                be a difference between the total duration of the produced audio and
                consumed by sink.
                It compensates for the time the buffers need
                to reach the sink after being sent from mixer and prevents 'cracks'
                produced on every interval because of audio samples being late.
                """,
                default: 50 |> Time.millisecond()
              ],
              caps: [
                type: :struct,
                spec: Caps.t(),
                description: """
                The value defines a raw audio format of pads connected to the
                element. It should be the same for all the pads.
                """
              ],
              timer: [
                type: :module,
                description: """
                Module implementing `#{inspect(Timer)}` behaviour used as timer for ticks.
                """,
                default: Timer.Erlang
              ]

  def_output_pad :output, mode: :push, caps: Caps

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :bytes,
    caps: Caps,
    options: [
      mute: [
        type: :boolean,
        spec: boolean(),
        default: @default_mute_val,
        description: """
        Determines whether the pad will be muted from the start.
        """
      ]
    ]

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

    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        interval: interval,
        outputs: %{},
        next_tick_time: nil,
        timer_ref: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    %{
      interval: interval,
      in_delay: in_delay,
      timer: timer
    } = state

    {:ok, timer_ref} = timer.start_sender(self(), interval, in_delay)

    state = %{
      state
      | timer_ref: timer_ref,
        next_tick_time: timer.current_time() + in_delay
    }

    {{:ok, generate_demands(state)}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    %{
      timer_ref: timer_ref,
      timer: timer,
      outputs: outputs
    } = state

    timer_ref |> timer.stop_sender()

    outputs =
      outputs
      |> Enum.map(fn {pad, data} ->
        {pad, %{data | queue: <<>>, skip: 0, mute: @default_mute_val}}
      end)
      |> Map.new()

    {:ok, %{state | timer_ref: nil, outputs: outputs}}
  end

  @impl true
  def handle_pad_added(pad, ctx, state) do
    state =
      state
      |> Bunch.Access.put_in([:outputs, pad], %{
        queue: <<>>,
        sos: false,
        eos: false,
        skip: 0,
        mute: ctx.options[:mute]
      })

    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event.StartOfStream{}, _ctx, state) do
    %{next_tick_time: next, caps: caps, interval: interval} = state
    default_demand = state |> get_default_demand

    now = state.timer.current_time()
    time_to_tick = (next - now) |> max(0)

    {demand, state} =
      if time_to_tick < interval do
        silent_prefix = caps |> Caps.sound_of_silence(interval - time_to_tick)
        state = state |> Bunch.Access.put_in([:outputs, pad, :queue], silent_prefix)
        {default_demand - byte_size(silent_prefix), state}
      else
        # possible if in_delay is greater than interval
        to_skip = (time_to_tick - interval) |> Caps.time_to_bytes(caps)
        state = state |> Bunch.Access.put_in([:outputs, pad, :skip], to_skip)
        {to_skip + default_demand, state}
      end

    state = state |> Bunch.Access.put_in([:outputs, pad, :sos], true)
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
  def handle_other(
        {:tick, _time} = tick,
        %{playback_state: :playing} = ctx,
        %{out_delay: out_delay, caps: caps} = state
      )
      when out_delay > 0 do
    silence =
      caps
      |> Caps.sound_of_silence(out_delay)
      ~> {:buffer, {:output, %Buffer{payload: &1}}}

    with {{:ok, actions}, state} <- handle_other(tick, ctx, %{state | out_delay: 0}) do
      {{:ok, [silence | actions]}, state}
    end
  end

  def handle_other({:tick, time}, %{playback_state: :playing}, state) do
    %{
      outputs: outputs
    } = state

    payload = state |> mix_tracks

    demand = state |> get_default_demand
    outputs = outputs |> update_outputs(demand)

    state = %{state | outputs: outputs, next_tick_time: time}

    demands = state |> generate_demands
    actions = [{:buffer, {:output, %Buffer{payload: payload}}} | demands]

    {{:ok, actions}, state}
  end

  def handle_other({:mute, pad_ref}, _ctx, state) do
    do_mute(pad_ref, true, state)
  end

  def handle_other({:unmute, pad_ref}, _ctx, state) do
    do_mute(pad_ref, false, state)
  end

  def handle_other(_message, _ctx, state) do
    {:ok, state}
  end

  defp do_mute(pad_ref, mute?, %{outputs: outputs} = state) do
    state =
      if outputs |> Map.has_key?(pad_ref) do
        state |> Bunch.Access.put_in([:outputs, pad_ref, :mute], mute?)
      else
        warn("Unmute error: No such pad #{inspect(pad_ref)}")
        state
      end

    {:ok, state}
  end

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

  defp update_outputs(outputs, skip_to_add) do
    outputs
    |> Enum.filter(fn {_pad, %{eos: eos}} -> not eos end)
    |> Enum.map(fn {pad, %{sos: started?, queue: queue, skip: skip} = data} ->
      if started? do
        skip = skip + skip_to_add - byte_size(queue)
        {pad, %{data | queue: <<>>, skip: skip}}
      else
        {pad, data}
      end
    end)
    |> Map.new()
  end

  defp generate_demands(state) do
    demand = get_default_demand(state)

    state.outputs
    |> Enum.flat_map(fn {pad, %{skip: skip, sos: started?}} ->
      if started? do
        [demand: {pad, demand + skip}]
      else
        []
      end
    end)
  end

  defp get_default_demand(%{interval: interval, caps: caps}) do
    interval |> Caps.time_to_bytes(caps)
  end
end
