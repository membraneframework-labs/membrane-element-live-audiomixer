defmodule Membrane.Element.LiveAudioMixer.Test do
  use ExUnit.Case, async: false

  alias Membrane.{Buffer, Event}
  alias Membrane.Time
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Common.AudioMix

  @module Membrane.Element.LiveAudioMixer.Source

  @interval 1 |> Time.second()
  @delay 500 |> Time.milliseconds()
  @caps %Caps{sample_rate: 48_000, format: :s16le, channels: 2}

  @default_options %{
    interval: @interval,
    delay: @delay,
    caps: @caps
  }

  @empty_state %{
    interval: @interval,
    delay: @delay,
    caps: @caps,
    sinks: %{},
    interval_start_time: nil,
    expected_tick_duration: nil,
    timer_ref: nil,
    playing: false
  }

  @dummy_state %{
    @empty_state
    | sinks: %{
        :sink_1 => %{queue: <<123>>, eos: false},
        :sink_2 => %{queue: <<321>>, eos: false},
        :sink_3 => %{queue: <<123>>, eos: false}
      },
      interval_start_time: 123,
      expected_tick_duration: @interval,
      timer_ref: :mtimer,
      playing: true
  }

  test "handle_init/1 should create an empty state" do
    assert {:ok, state} = @module.handle_init(@default_options)
    assert @empty_state = state
    assert state.playing == false
  end

  describe "handle_play should" do
    test "set playing to true" do
      assert {{:ok, _actions}, %{playing: true}} = @module.handle_play(@dummy_state)
    end

    test "start a timer" do
      assert {{:ok, _actions}, %{}} = @module.handle_play(@dummy_state)
      assert_received({:send_after, @interval, :tick, _, _})
    end

    test "generate demands for all the sinks" do
      {{:ok, actions}, _state} = @module.handle_play(@dummy_state)

      1..3
      |> Enum.each(fn id ->
        sink = :"sink_#{id}"
        demand = @interval |> Caps.time_to_bytes(@caps)
        assert actions |> Enum.any?(&match?({:demand, {^sink, :self, {:set_to, ^demand}}}, &1))
      end)
    end

    test "generate the appropriate amount of silence" do
      {{:ok, actions}, _state} = @module.handle_play(@dummy_state)
      silence = (@delay + @interval) |> AudioMix.generate_silence(@caps)
      assert actions |> Enum.any?(&match?({:buffer, {:source, %Buffer{payload: ^silence}}}, &1))
    end
  end

  describe "handle_prepare should" do
    test "do nothing if previous playback state is not set to :playing" do
      assert {:ok, @dummy_state} == @module.handle_prepare(:mock, @dummy_state)
      refute_received({:send_after, _time, _msg, _dest, _opts})
      refute_received({:calcel_timer, _timer_ref, _options})
    end

    test "set playing to false on :playing" do
      assert {:ok, %{playing: false}} = @module.handle_prepare(:playing, @dummy_state)
    end

    test "cancel the timer and clear its reference on :playing" do
      assert {:ok, %{timer_ref: nil}} = @module.handle_prepare(:playing, @dummy_state)
      assert_received({:cancel_timer, :mtimer, _options})
    end

    test "clear queues of all the sinks" do
      assert {:ok, %{sinks: sinks}} = @module.handle_prepare(:playing, @dummy_state)

      assert sinks
             |> Enum.all?(fn {_pad, %{queue: queue, eos: eos}} ->
               queue == <<>> and eos == false
             end)

      assert sinks |> Map.to_list() |> length == 3
    end
  end

  test "handle_pad_removed should set eos to true for a given pad" do
    assert {:ok, %{sinks: sinks}} = @module.handle_pad_removed(:sink_1, :context, @dummy_state)
    assert sinks |> Map.to_list() |> length == 3
    assert sinks |> Enum.all?(fn {pad, %{eos: eos}} ->
      (pad == :sink_1) == eos
    end)
  end
end
