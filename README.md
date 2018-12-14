# Membrane.Element.LiveAudioMixer

The element is a simple mixer that compines audio from different sources.
It is designed for use as a live source, meaning it will produce audio stream
even if some (or all) of the sources fail to provide enough data.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `membrane_element_live_audiomixer` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_element_live_audiomixer, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/membrane_element_live_audiomixer](https://hexdocs.pm/membrane_element_live_audiomixer).
