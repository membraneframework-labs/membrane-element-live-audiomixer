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
                of time because of lack of information). Even worse: it's possible
                that we will hear silence most of the time, because demands are not
                exact and the module demands `interval + delay` bytes. On the other
                hand, if delay is too big, we will run out of memory, because we
                will be supposed to store all the information we get from the sinks.
                The first interval of time is filled with silence and is not counted
                as a part of the delay.
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
      delay: delay,
      caps: caps,
      sinks: %{},
      playing: false,
      timer_ref: nil,
      prev_time: nil
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

    timer_ref = interval |> Helper.Timer.send_after(:tick)
    silence = (interval + delay) |> AudioMix.generate_silence(caps)

    actions =
      [
        buffer: {:source, %Buffer{payload: silence}}
      ] ++ generate_demands(state)

    new_state = %{
      state
      | playing: true,
        timer_ref: timer_ref,
        prev_time: Time.monotonic_time()
    }

    {{:ok, actions}, new_state}
  end

  @impl true
  def handle_prepare(:playing, state) do
    %{
      timer_ref: timer_ref,
      sinks: sinks
    } = state

    timer_ref |> :timer.cancel()

    sinks =
      sinks
      |> Enum.map(fn {sink, {_queue, eos}} ->
        {sink, {<<>>, eos}}
      end)
      |> Map.new()

    {:ok, %{state | playing: false, timer_ref: nil, sinks: sinks}}
  end

  def handle_prepare(_previous_playback_state, state), do: {:ok, state}

  @impl true
  def handle_pad_added(pad, _context, state) do
    # Should I remove this function?
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    # Should I remove this function?
    state = state |> Helper.Map.update_in([:sinks, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event{type: :sos}, _context, state) do
    %{
      interval: interval,
      caps: caps,
      delay: delay
    } = state

    actions = [
      demand: {
        pad,
        :self,
        {:set_to, interval |> Caps.time_to_bytes(caps)}
      }
    ]

    # We can demand from the pad here or we can just wait for the next tick of the timer. What to do?
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

    # IO.puts("payload: #{byte_size(payload)}")

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

    %{
      prev_time: prev_time,
      interval: interval,
      caps: caps
    } = state

    now_time = Time.monotonic_time()
    time_diff = now_time - prev_time

    number_of_bytes = time_diff |> Caps.time_to_bytes(caps)
    timer_ref = interval |> Helper.Timer.send_after(:tick)

    payloads =
      state.sinks
      |> Enum.map(fn {_pad, %{queue: queue, eos: _eos}} ->
        if byte_size(queue) >= number_of_bytes do
          <<head::binary-size(number_of_bytes), _tail::binary>> = queue
          head
        else
          # IO.puts("#{byte_size(queue)} : #{number_of_bytes}")
          <<>>
          queue
        end
      end)
      |> Enum.filter(&(byte_size(&1) > 0))

    payloads =
      if payloads == [] do
        [time_diff |> AudioMix.generate_silence(caps)]
      else
        payloads
      end

    sinks =
      state.sinks
      |> Enum.map(fn {pad, %{queue: queue, eos: eos}} ->
        queue =
          if byte_size(queue) >= number_of_bytes do
            <<_head::binary-size(number_of_bytes), tail::binary>> = queue
            tail
          else
            <<>>
          end

        {pad, %{queue: queue, eos: eos}}
      end)
      |> Enum.filter(fn {pad, %{queue: queue, eos: eos}} ->
        byte_size(queue) > 0 or eos == false
      end)
      |> Map.new()

    new_state = %{state | sinks: sinks, timer_ref: timer_ref, prev_time: now_time}
    demands = new_state |> generate_demands

    actions =
      [
        buffer: {
          :source,
          %Buffer{payload: AudioMix.mix(payloads, caps)}
        }
      ] ++ demands

    {{:ok, actions}, new_state}
  end

  def handle_other(_message, state), do: {:ok, state}

  defp generate_demands(state) do
    %{
      interval: interval,
      caps: caps,
      sinks: sinks,
      delay: delay
    } = state

    sinks
    |> Enum.map(fn {pad, %{queue: queue}} ->
      {
        :demand,
        {pad, :self, {:set_to, Caps.time_to_bytes(interval, caps) - byte_size(queue)}}
      }
    end)
  end
end
