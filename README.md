# Membrane.Element.LiveAudioMixer

The element is just a simple mixer which mixes sounds from different sources. One
can connect several different sources to the element and it will send mixed sounds
every `interval` to the next element. The next element should be able to consume
the produced amount of data, otherwise the internal buffer will be overflowed.

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
