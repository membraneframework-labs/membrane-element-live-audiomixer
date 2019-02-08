# [Work in progress] Membrane.Element.LiveAudioMixer

The element is a simple mixer that compines audio from different sources.
It is designed for use as a live source, meaning it will produce audio stream
even if some (or all) of the sources fail to provide enough data.

## Installation

This package is still in development, if you want to test it, you can install it from github:

```elixir
def deps do
  [
    {:membrane_element_live_audiomixer, github: "membraneframework/membrane-element-live-audiomixer"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
