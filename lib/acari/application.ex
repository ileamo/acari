defmodule Acari.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    IO.puts("START ACARI")
    :ssl.start()
    # List all child processes to be supervised
    children = [
      Acari.Config,
      Acari.LinkSupervisor,
      Acari.Iface
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Acari.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
