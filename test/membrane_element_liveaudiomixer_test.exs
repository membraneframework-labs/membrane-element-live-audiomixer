defmodule Membrane.Element.LiveAudioMixer.Test do
  use ExUnit.Case, async: true

  @module Membrane.Element.LiveAudioMixer.Source

  @empty_state %{
    sinks: %{}
  }

  setup do
    [
      state: %{
        @empty_state
        | sinks: %{
            :sink_1 => :dummy_sink_1,
            :sink_2 => :dummy_sink_2,
            :sink_3 => :dummy_sink_3
          }
      }
    ]
  end

  test "handle_init/1 should create an empty state" do
    assert @module.handle_init(%{:option => :dummy}) == {:ok, @empty_state}
  end

  describe "handle_pad_removed should" do
    test "delete the dynamic sink pad from the map", context do
      state = context.state
      assert @module.handle_pad_removed({:dynamic, :sink, 42}, %{direction: :sink}, state)
    end
  end
end
