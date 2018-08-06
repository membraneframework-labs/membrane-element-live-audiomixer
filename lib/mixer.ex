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
                spec: Membrane.Time.t(),
                description: """
                The value defines an interval of sending mixed stream to the next element
                Be aware that if a pad doesn't send enough bytes, then all the bytes sent by
                the pad in the last interval timeframe will be discarded. If no pad sends
                enough bytes, then silence will be sent to the next element. The interval is
                not exact, it's just an estimation.
                """,
                default: 1 |> Membrane.Time.second()
              ],
              caps: [
                type: :struct,
                spec: Caps.t(),
                description: """
                The value defines a raw audio format of pads connected to the element.
                It should be the same for all the pads.
                """
              ]

  def_known_source_pads source: {:always, :push, Caps}
  def_known_sink_pads sink: {:on_request, {:pull, demand_in: :bytes}, Caps}

  @impl true
  def handle_init(options) do
    %{
      interval: interval,
      caps: caps
    } = options

    state = %{
      interval: 1 |> Membrane.Time.second(),
      caps: caps,
      sinks: %{},
      playing: false,
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_play(state) do
    timer_ref = Process.send_after(self(), :tick, Time.to_milliseconds(state.interval))
    {:ok, %{state | playing: true, timer_ref: timer_ref}}
  end

  @impl true
  def handle_prepare(:playing, state) do
    state.timer_ref |> Process.cancel_timer()

    sinks =
      state.sinks
      |> Enum.map(fn {sink, {_queue, eos, sz}} ->
        {sink, {<<>>, eos, 0}}
      end)
      |> Enum.into(%{})

    {:ok, %{state | playing: false, timer_ref: nil, sinks: sinks}}
  end

  def handle_prepare(_previous_playback_state, state), do: {:ok, state}

  @impl true
  def handle_pad_added(pad, _context, state) do
    IO.puts("ADDED: #{inspect(pad)}")
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    IO.puts("REMOVED: #{inspect(pad)}")
    state = state |> Helper.Map.update_in([:sinks, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  @impl true
  def handle_event(pad, %Event{type: :sos}, _context, state) do
    %{
      interval: interval,
      caps: caps
    } = state
    IO.puts("The start of the stream from the pad #{inspect(pad)}, demand: #{interval |> Caps.time_to_bytes(caps)}")

    state = state |> Helper.Map.put_in([:sinks, pad], %{queue: <<>>, eos: false, sz: 0})
    {{:ok, demand: {pad, :self, {:set_to, interval |> Caps.time_to_bytes(caps)}}}, state}
  end

  def handle_event(pad, %Event{type: :eos}, _context, state) do
    IO.puts("The End of the stream from pad: #{inspect(pad)}")
    state = state |> Helper.Map.update_in([:sinks, pad], &%{&1 | eos: true})
    {:ok, state}
  end

  def handle_event(_pad, _event, _context, state) do
    {:ok, state}
  end

  @impl true
  def handle_process1(pad, buffer, _context, state) do
    IO.puts("Handle process from #{inspect(pad)}")
    %Buffer{payload: payload} = buffer
    #IO.puts("PAYLOAD: #{byte_size(payload)}")
    state =
      state
      |> Helper.Map.update_in([:sinks, pad], fn %{queue: queue, eos: eos, sz: sz} ->
        #IO.puts(byte_size(queue <> payload))
        %{queue: queue <> payload, eos: eos, sz: sz + byte_size(payload)}
      end)

    {:ok, state}
  end

  @impl true
  def handle_other(:tick, %{playing: true} = state) do
    IO.puts("TICK")

    %{
      interval: interval,
      caps: caps
    } = state

    number_of_bytes = interval |> Caps.time_to_bytes(caps)
    timer_ref = Process.send_after(self(), :tick, Time.to_milliseconds(interval) - 100)

    demands =
      state.sinks
      |> Enum.map(fn {pad, _value} ->
        {:demand, {pad, :self,  {:set_to, interval |> Caps.time_to_bytes(caps)}}}
      end)

  #  IO.puts("bts: #{number_of_bytes}")

    payloads =
      state.sinks
      |> Enum.map(fn {pad, %{queue: queue, eos: _eos, sz: sz}} ->
        #IO.puts(byte_size(queue))
        if byte_size(queue) >= number_of_bytes do
          <<head::binary-size(number_of_bytes), tail::binary>> = queue
          #IO.puts("#{is_bitstring(head)} #{is_binary(queue)} #{bits}")
          head
        else
          <<>>
        end
      end)

  #  IO.puts("Length: #{length(payloads)}")

    sinks =
      state.sinks
      |> Enum.map(fn {pad, %{queue: queue, eos: eos, sz: sz}} ->
        queue =
          if byte_size(queue) >= number_of_bytes do
            <<head::binary-size(number_of_bytes), tail::binary>> = queue
            tail
          else
            queue
          end
        {pad, %{queue: queue, eos: eos, sz: sz}}
      end)
      |> Map.new

    #IO.puts("#{inspect(sinks)}")
    #IO.puts("#{inspect(demands)}")
    #[head | _tail] = payloads
    #IO.puts("SIZE:")
    #IO.puts(is_binary(head))
    #IO.puts("#{byte_size(head)}")
    {{:ok, demands ++ [buffer: {:source, %Buffer{payload: AudioMix.mix(payloads, caps)}}]}, %{state | sinks: sinks, timer_ref: timer_ref}}
    # {:ok, state}
  end

  def handle_other(_message, state), do: {:ok, state}
end
