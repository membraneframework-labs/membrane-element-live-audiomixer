defmodule Membrane.Element.LiveAudioMixer.Test do
  use ExUnit.Case, async: false

  alias Membrane.Helper
  alias Membrane.{Buffer, Event}
  alias Membrane.Time
  alias Membrane.Caps.Audio.Raw, as: Caps

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
    ticks: 0,
    timer_ref: nil,
    playing: false
  }

  @dummy_state %{
    @empty_state
    | sinks: %{
        :sink_1 => %{queue: <<1, 2, 3>>, eos: false, skip: 0},
        :sink_2 => %{queue: <<3, 2, 1>>, eos: false, skip: 0},
        :sink_3 => %{queue: <<1, 2, 3>>, eos: false, skip: 0}
      },
      start_playing_time: 0,
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
      assert {{:ok, _actions}, %{timer_ref: timer_ref}} = @module.handle_play(@dummy_state)
      assert_received({:send_after, @interval, :tick, _, _})
      assert timer_ref != nil
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
      silence = @caps |> Caps.sound_of_silence(@interval + @delay)
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

    assert sinks
           |> Enum.all?(fn {pad, %{eos: eos}} ->
             pad == :sink_1 == eos
           end)
  end

  describe "handle_event should" do
    test "do nothing if the event is not SOS nor EOS" do
      assert {:ok, @dummy_state} == @module.handle_event(:sink_1, %Event{}, [], @dummy_state)
      refute_received({:send_after, _time, _msg, _dest, _opts})
      refute_received({:calcel_timer, _timer_ref, _options})
    end

    test "set eos for the given pad on true (on Event{type: :eos})" do
      assert {:ok, %{sinks: sinks}} =
               @module.handle_event(:sink_1, %Event{type: :eos}, [], @dummy_state)

      assert sinks |> Map.to_list() |> length == 3

      assert sinks
             |> Enum.all?(fn {pad, %{eos: eos}} ->
               pad == :sink_1 == eos
             end)
    end

    test "add an instance in sinks map (on Event{type: :sos})" do
      assert {{:ok, _actions}, %{sinks: sinks}} =
               @module.handle_event(:sink_4, %Event{type: :sos}, [], @dummy_state)

      assert sinks |> Map.to_list() |> length == 4
      assert sinks |> Map.has_key?(:sink_4)
      assert %{queue: <<>>, eos: false} = sinks[:sink_4]
    end

    test "generate the appropriate demand for a given pad" do
      sink = :sink_4

      assert {{:ok, actions}, _state} =
               @module.handle_event(sink, %Event{type: :sos}, [], @dummy_state)

      demand = @interval |> Caps.time_to_bytes(@caps)
      assert actions |> Enum.any?(&match?({:demand, {^sink, :self, {:set_to, ^demand}}}, &1))
    end
  end

  test "handle_process1 should append to the queue the payload of the buffer" do
    assert {:ok, %{sinks: sinks}} =
             @module.handle_process1(:sink_1, %Buffer{payload: <<5, 5, 5>>}, [], @dummy_state)

    assert %{queue: <<1, 2, 3, 5, 5, 5>>, eos: false} = sinks[:sink_1]
    assert %{queue: <<3, 2, 1>>, eos: false} = sinks[:sink_2]
    assert %{queue: <<1, 2, 3>>, eos: false} = sinks[:sink_3]
    assert sinks |> Map.to_list() |> length == 3
  end

  describe "handle_other should" do
    test "do nothing if it gets something different than :tick" do
      assert {:ok, @dummy_state} == @module.handle_other(:not_a_tick, @dummy_state)
      refute_received({:send_after, _time, _msg, _dest, _opts})
      refute_received({:calcel_timer, _timer_ref, _options})
    end

    test "do nothing if state.playing is false" do
      assert {:ok, %{@dummy_state | playing: false}} ==
               @module.handle_other(:tick, %{@dummy_state | playing: false})

      refute_received({:send_after, _time, _msg, _dest, _opts})
      refute_received({:calcel_timer, _timer_ref, _options})
    end

    test "start a timer" do
      assert {{:ok, _actions}, %{timer_ref: timer_ref}} = @module.handle_play(@dummy_state)
      assert_received({:send_after, _interval, :tick, _, _})
      assert timer_ref != nil
    end

    test "filter out pads with eos: true and clear queues for all the others sinks" do
      state =
        @dummy_state
        |> Helper.Map.update_in([:sinks, :sink_1], fn %{queue: queue, eos: false} ->
          %{queue: queue, eos: true}
        end)

      state =
        state
        |> Helper.Map.update_in([:sinks, :sink_2], fn %{queue: queue, eos: false} ->
          %{queue: queue, eos: true}
        end)

      assert {{:ok, _actions}, %{sinks: sinks}} = @module.handle_other(:tick, state)
      assert %{queue: "", eos: false} = sinks[:sink_3]
      assert sinks |> Map.to_list() |> length == 1
    end

    test "generate demands" do
      state =
        @dummy_state
        |> Helper.Map.update_in([:sinks, :sink_1], fn %{queue: queue, eos: false} ->
          %{queue: queue, eos: true}
        end)

      assert {{:ok, actions}, %{sinks: sinks}} = @module.handle_other(:tick, state)
      demand = @interval |> Caps.time_to_bytes(@caps)
      assert actions |> Enum.any?(&match?({:demand, {:sink_2, :self, {:set_to, ^demand}}}, &1))
      assert actions |> Enum.any?(&match?({:demand, {:sink_3, :self, {:set_to, ^demand}}}, &1))
      assert sinks |> Map.to_list() |> length == 2
    end

    test "mix payloads (test1, everything is fine)" do
      state =
        1..3
        |> Enum.reduce(@dummy_state, fn id, state ->
          sink = :"sink_#{id}"

          state
          |> Helper.Map.update_in([:sinks, sink], fn %{queue: _queue, eos: eos} ->
            %{queue: generate(<<id>>, @interval, @caps), eos: eos}
          end)
        end)

      assert {{:ok, actions}, %{}} = @module.handle_other(:tick, state)
      assert {:source, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<6>>, @interval, @caps)
    end

    test "mix payloads (test2, something is broken)" do
      state =
        1..3
        |> Enum.reduce(@dummy_state, fn id, state ->
          sink = :"sink_#{id}"

          if id == 2 do
            state
          else
            state
            |> Helper.Map.update_in([:sinks, sink], fn %{queue: _queue, eos: eos} ->
              %{queue: generate(<<id>>, @interval, @caps), eos: eos}
            end)
          end
        end)

      assert {{:ok, actions}, %{}} = @module.handle_other(:tick, state)
      assert {:source, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<4>>, @interval, @caps)
    end

    test "mix payloads (test3, everything is broken, silence should be generated)" do
      assert {{:ok, actions}, %{}} = @module.handle_other(:tick, @dummy_state)
      assert {:source, %Buffer{payload: payload}} = actions[:buffer]
      assert payload == generate(<<0>>, @interval, @caps)
    end

    defp generate(byte, interval, caps) do
      length = interval |> Caps.time_to_bytes(caps)
      byte |> String.duplicate(length)
    end
  end
end
