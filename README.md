# Acari

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `acari` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:acari, "~> 0.1.0"}
  ]
end
```



Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/acari](https://hexdocs.pm/acari).
-----

  For IPv4 addresses, beam needs to have privileges to configure interfaces.
  To add cap_net_admin capabilities:

  sudo setcap cap_net_admin=ep /path/to/bin/beam.smp cap_net_admin=ep /bin/ip
