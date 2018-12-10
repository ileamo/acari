defmodule Acari.TunSup do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @impl true
  def init(params) do
    IO.puts("TUN_SUP")
    :ssl.start()
    # List all child processes to be supervised
    children = [
      {Acari.TunMan, params |> Map.put(:tun_sup_pid, self())}
    ]

    opts = [strategy: :one_for_all, name: Acari.Supervisor]
    Supervisor.init(children, opts)
  end
end
