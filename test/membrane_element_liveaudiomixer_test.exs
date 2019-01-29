defmodule Membrane.Element.LiveAudioMixer.Test do
  use ExUnit.Case, async: false
  use Mockery

  alias Bunch
  alias Membrane.{Buffer, Event}
  alias Membrane.Time
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Element.CallbackContext, as: Ctx
  alias Membrane.Element.LiveAudioMixer.Timer

  @module Membrane.Element.LiveAudioMixer
  @time Membrane.Time

  @interval 200 |> Time.millisecond()

  @delay 100 |> Time.millisecond()

  @caps %Caps{sample_rate: 48_000, format: :s16le, channels: 2}

  @mute_by_default false

  @default_options %Membrane.Element.LiveAudioMixer{
    interval: @interval,
    delay: @delay,
    caps: @caps,
    mute_by_default: @mute_by_default
  }

  @empty_state %{
    interval: @interval,
    delay: @delay,
    caps: @caps,
    outputs: %{},
    mute_by_default: @mute_by_default,
    start_playing_time: nil,
    tick: 1,
    timer_ref: nil
  }

  @dummy_state %{
    @empty_state
    | outputs: %{
        :sink_1 => %{queue: <<1, 2, 3>>, eos: false, skip: 0, mute: @mute_by_default},
        :sink_2 => %{queue: <<3, 2, 1>>, eos: false, skip: 0, mute: @mute_by_default},
        :sink_3 => %{queue: <<1, 2, 3>>, eos: false, skip: 0, mute: @mute_by_default}
      },
      start_playing_time: 0,
      timer_ref: :mtimer
  }

  def assert_interval_rounding(input_interval, expected, sample_rate) do
    caps = %{@caps | sample_rate: sample_rate}

    opts = %{
      @default_options
      | interval: input_interval |> Time.millisecond(),
        caps: caps
    }

    assert {:ok, state} = @module.handle_init(opts)
    assert state.interval == Time.millisecond(expected)
    frames_per_interval = Caps.time_to_frames(state.interval, caps, & &1)

    assert_in_delta(frames_per_interval, round(frames_per_interval), 1.0e-10, """
    Numbers of frames per interval should be an integer.
    Interval = #{state.interval} ms,
    frames = #{frames_per_interval},
    sample rate = #{sample_rate} Hz
    """)
  end

  describe "handle_init/1 should" do
    test "create an empty state" do
      assert {:ok, state} = @module.handle_init(@default_options)
      assert @empty_state == state
    end

    test "properly adjust the interval if needed" do
      assert_interval_rounding(100, 100, 44_100)
      assert_interval_rounding(1, 10, 44_100)
      assert_interval_rounding(28, 30, 44_100)
      assert_interval_rounding(43, 50, 44_100)

      assert_interval_rounding(1, 20, 22_050)
      assert_interval_rounding(30, 40, 22_050)

      assert_interval_rounding(1, 40, 11_025)
      assert_interval_rounding(52, 80, 11_025)
    end
  end

  describe "handle_prepared_to_playing should" do
    test "start a timer" do
      mock(Timer, :start_sender, {:ok, :mtimer})

      assert {{:ok, _actions}, %{timer_ref: timer_ref}} =
               @module.handle_prepared_to_playing(%{}, @dummy_state)

      pid = self()
      interval = @interval |> Time.to_milliseconds()
      delay = @delay |> Time.to_milliseconds()

      assert_called(Timer, :start_sender, [^pid, ^interval, ^delay])
      assert timer_ref == :mtimer
    end

    test "generate demands for all the outputs" do
      mock(Timer, :start_sender, {:ok, :mtimer})
      {{:ok, actions}, _state} = @module.handle_prepared_to_playing(%{}, @dummy_state)

      1..3
      |> Enum.each(fn id ->
        sink = :"sink_#{id}"
        demand = @interval |> Caps.time_to_bytes(@caps)
        assert actions |> Enum.any?(&match?({:demand, {^sink, ^demand}}, &1))
      end)
    end

    test "generate the appropriate amount of silence" do
      mock(Timer, :start_sender, {:ok, :mtimer})
      {{:ok, actions}, _state} = @module.handle_prepared_to_playing(%{}, @dummy_state)
      silence = @caps |> Caps.sound_of_silence(@interval + @delay)
      assert actions |> Enum.any?(&match?({:buffer, {:output, %Buffer{payload: ^silence}}}, &1))
    end
  end

  describe "handle_playing_to_prepared should" do
    test "cancel the timer and clear its reference on :playing" do
      mock(Timer, :stop_sender, :ok)
      assert {:ok, %{timer_ref: nil}} = @module.handle_playing_to_prepared(%{}, @dummy_state)
      assert_called(Timer, :stop_sender, [:mtimer])
    end

    test "clear queues of all the outputs" do
      mock(Timer, :stop_sender, :ok)
      assert {:ok, %{outputs: outputs}} = @module.handle_playing_to_prepared(%{}, @dummy_state)

      assert outputs
             |> Enum.all?(fn {_pad, %{queue: queue, eos: eos}} ->
               queue == <<>> and eos == false
             end)

      assert outputs |> Map.to_list() |> length == 3
    end
  end

  @event_ctx %Ctx.Event{
    pads: %{},
    playback_state: :playing
  }

  describe "handle_pad_added should" do
    test "add an instance to outputs map" do
      assert {:ok, %{outputs: outputs}} = @module.handle_pad_added(:sink_4, %{}, @dummy_state)

      assert outputs |> Map.to_list() |> length == 4
      assert outputs |> Map.has_key?(:sink_4)
      assert %{queue: <<>>, eos: false, skip: 0, mute: @mute_by_default} = outputs[:sink_4]
    end
  end

  describe "handle_event should" do
    test "do nothing if the event is not SOS nor EOS" do
      assert {:ok, @dummy_state} =
               @module.handle_event(:sink_1, %Event.Underrun{}, @event_ctx, @dummy_state)

      refute_called(Timer, :send_after)
      refute_called(Timer, :cancel_timer)
    end

    test "set eos for the given pad on true (on EndOfStream event)" do
      assert {:ok, %{outputs: outputs}} =
               @module.handle_event(:sink_1, %Event.EndOfStream{}, @event_ctx, @dummy_state)

      assert outputs |> Map.to_list() |> length == 3

      assert {[sink_1: %{eos: true}], not_eos} =
               Enum.split_with(outputs, fn {pad, _} -> pad == :sink_1 end)

      assert not_eos
             |> Enum.all?(fn {_, %{eos: eos}} ->
               eos == false
             end)
    end

    test "generate the appropriate demand for a given pad (on StartOfStream event)" do
      sink = :sink_4

      assert {{:ok, actions}, _state} =
               @module.handle_event(sink, %Event.StartOfStream{}, @event_ctx, @dummy_state)

      demand = @interval |> Caps.time_to_bytes(@caps)
      assert actions |> Enum.any?(&match?({:demand, {^sink, ^demand}}, &1))
    end
  end

  describe "handle_process should" do
    test "append to the queue the payload of the buffer is skip is 0" do
      assert {:ok, %{outputs: outputs}} =
               @module.handle_process(:sink_1, %Buffer{payload: <<5, 5, 5>>}, [], @dummy_state)

      assert %{queue: <<1, 2, 3, 5, 5, 5>>, eos: false} = outputs[:sink_1]
      assert %{queue: <<3, 2, 1>>, eos: false} = outputs[:sink_2]
      assert %{queue: <<1, 2, 3>>, eos: false} = outputs[:sink_3]
      assert outputs |> Map.to_list() |> length == 3
    end

    test "change skip is skip is too large" do
      state =
        @dummy_state
        |> Bunch.Access.update_in([:outputs, :sink_1], fn data ->
          %{data | skip: 123}
        end)

      assert {:ok, %{outputs: outputs}} =
               @module.handle_process(:sink_1, %Buffer{payload: <<5, 5, 5>>}, [], state)

      assert %{queue: <<1, 2, 3>>, eos: false, skip: 120} = outputs[:sink_1]
    end

    test "set skip to 0 and append the payload to the queue if byte_size(paylaod) >= skip" do
      state =
        @dummy_state
        |> Bunch.Access.update_in([:outputs, :sink_1], fn data ->
          %{data | skip: 1}
        end)

      assert {:ok, %{outputs: outputs}} =
               @module.handle_process(:sink_1, %Buffer{payload: <<6, 7, 8>>}, [], state)

      assert %{queue: <<1, 2, 3, 7, 8>>, eos: false, skip: 0} = outputs[:sink_1]
    end
  end

  @other_ctx %Ctx.Other{
    pads: %{},
    playback_state: :playing
  }

  describe "handle_other should" do
    test "do nothing if it gets something different unknown" do
      assert {:ok, @dummy_state} == @module.handle_other(:not_a_tick, @other_ctx, @dummy_state)
    end

    test "ignore :tick if playback_state is false" do
      ctx = %{@other_ctx | playback_state: :prepared}
      assert {:ok, @dummy_state} == @module.handle_other(:tick, ctx, @dummy_state)
    end

    test "filter out pads with eos: true and clear queues for all the others outputs" do
      state =
        @dummy_state
        |> Bunch.Access.put_in([:outputs, :sink_1, :eos], true)
        |> Bunch.Access.put_in([:outputs, :sink_2, :eos], true)

      assert {{:ok, _actions}, %{outputs: outputs}} =
               @module.handle_other({:tick, 42}, @other_ctx, state)

      assert %{queue: "", eos: false} = outputs[:sink_3]
      assert outputs |> Map.to_list() |> length == 1
    end

    test "generate demands (normal mixing speed)" do
      state =
        @dummy_state
        |> Bunch.Access.put_in([:outputs, :sink_1, :eos], true)

      mock(@time, [monotonic_time: 0], @interval)

      assert {{:ok, actions}, %{outputs: outputs}} =
               @module.handle_other({:tick, 42}, @other_ctx, state)

      demand = @interval |> Caps.time_to_bytes(@caps)

      %{queue: queue_2} = state.outputs[:sink_2]
      %{queue: queue_3} = state.outputs[:sink_3]

      demand_2 = 2 * demand - byte_size(queue_2)
      demand_3 = 2 * demand - byte_size(queue_3)

      assert actions |> Enum.any?(&match?({:demand, {:sink_2, ^demand_2}}, &1))
      assert actions |> Enum.any?(&match?({:demand, {:sink_3, ^demand_3}}, &1))

      assert outputs |> Map.to_list() |> length == 2
    end

    test "update outputs" do
      state =
        @dummy_state
        |> Bunch.Access.update_in([:outputs, :sink_1], fn %{queue: _queue, eos: eos} = data ->
          %{data | queue: generate(<<1>>, @interval, @caps), eos: eos}
        end)

      mock(@time, [monotonic_time: 0], @interval)

      assert {{:ok, _actions}, %{outputs: outputs}} =
               @module.handle_other({:tick, 42}, @other_ctx, state)

      demand = @interval |> Caps.time_to_bytes(@caps)
      %{queue: queue_2} = state.outputs[:sink_2]
      %{queue: queue_3} = state.outputs[:sink_3]

      skip_2 = demand - byte_size(queue_2)
      skip_3 = demand - byte_size(queue_3)

      assert %{skip: 0} = outputs[:sink_1]
      assert %{skip: ^skip_2} = outputs[:sink_2]
      assert %{skip: ^skip_3} = outputs[:sink_3]
    end

    test "mix payloads when every input provided enough data" do
      state =
        1..3
        |> Enum.reduce(@dummy_state, fn id, state ->
          sink = :"sink_#{id}"

          state
          |> Bunch.Access.update_in([:outputs, sink], fn %{queue: _queue, eos: eos} = data ->
            %{data | queue: generate(<<id>>, @interval, @caps), eos: eos}
          end)
        end)

      assert {{:ok, actions}, %{}} = @module.handle_other({:tick, 42}, @other_ctx, state)
      assert {:output, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<6>>, @interval, @caps)
    end

    test "mix payloads when one input haven't provided data" do
      state =
        1..3
        |> Enum.reduce(@dummy_state, fn id, state ->
          sink = :"sink_#{id}"

          if id == 2 do
            state
          else
            state
            |> Bunch.Access.update_in([:outputs, sink], fn %{queue: _queue, eos: eos} = data ->
              %{data | queue: generate(<<id>>, @interval, @caps), eos: eos}
            end)
          end
        end)

      assert {{:ok, actions}, %{}} = @module.handle_other({:tick, 42}, @other_ctx, state)
      assert {:output, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<4>>, @interval, @caps)
    end

    test "generate silence when none of the inputs have provided data" do
      assert {{:ok, actions}, %{}} = @module.handle_other({:tick, 42}, @other_ctx, @dummy_state)
      assert {:output, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<0>>, @interval, @caps)
    end

    defp generate(byte, interval, caps) do
      length = interval |> Caps.time_to_bytes(caps)
      byte |> String.duplicate(length)
    end
  end
end
