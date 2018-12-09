defmodule Acari.TunSup do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    IO.puts("TUN_SUP")
    :ssl.start()
    # List all child processes to be supervised
    children = [
      Acari.Iface,
      Acari.SSLinkSup,
      Acari.TunMan
    ]

    opts = [strategy: :one_for_all, name: Acari.Supervisor]
    Supervisor.init(children, opts)
  end
end
