defmodule Membrane.Element.LiveAudioMixer.Source do
  use Membrane.Mixins.Log, tags: :membrane_element_live_audiomixer
  use Membrane.Element.Base.Filter
  use Membrane.Helper

  alias Membrane.{Event}
  alias Membrane.Caps.Audio.Raw, as: Caps

  def_options []
  def_known_source_pads source: {:always, :pull, Caps}
  def_known_sink_pads sink: {:on_request, {:pull, demand_in: :bytes}, Caps}

  @impl true
  def handle_init(_options) do
    state = %{
      sinks: %{}
    }
    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _context, state) do
    IO.puts("ADDED: #{inspect pad}")
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    IO.puts("REMOVED: #{inspect pad}")
    {:ok, state}
  end

  @impl true
  def handle_event(sink, %Event{type: :sos}, _context, state) do
    IO.puts("The start of the stream from pad: #{inspect sink}")
    state = state |> Helper.Map.put_in([:sinks, sink], %{queue: <<>>, eos: false})
    {:ok, state}
  end

  def handle_event(sink, %Event{type: :eos}, _context, state) do
    IO.puts("The End of the stream from pad: #{inspect sink}")
    state = state |> Helper.Map.remove_in([:sinks, sink])
    {:ok, state}
  end

  def handle_event(_pad, _event, _context, state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(:source, size, :bytes, _context, state) do
    IO.puts("DEMAND FROM SOURCE")
    demands =
      state.sinks
      |> Enum.map(fn {pad, value} ->
        {:demand, {pad, size}}
      end)
    IO.puts("#{inspect demands}")
    {{:ok, demands}, state}
  end

  @impl true
  def handle_process1(pad, buffer, _context, state) do
    IO.puts("Handle process from #{inspect pad}")
    {{:ok, [buffer: {:source, buffer}]}, state}
  end
end
