defmodule AcariClient.TunCreator do
  use GenServer
  require Logger

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    IO.puts("TUN_CREATOR")
    :ok = Acari.start_tun("cl", self())
    {:ok, state}
  end

  @impl true
  def handle_cast({:tun_started, tun_name}, state) do
    Logger.debug("Acari client receive :tun_started from #{tun_name}")
    restart_tunnel()
    {:noreply, state}
  end

  defp restart_tunnel() do
    # :ok = Acari.start_tun("cl", self())

    # start link M1
    link = "m1"
    {:ok, request} = Poison.encode(%{id: "nsg1700_1812000999", link: link})

    {:ok, _pid} =
      Acari.add_link("cl", link, fn
        :connect ->
          connect(%{host: "localhost", port: 7000}, request)

        :restart ->
          true
      end)

    # start link M1
    link = "m2"
    {:ok, request} = Poison.encode(%{id: "nsg1700_1812000999", link: link})

    {:ok, _pid} =
      Acari.add_link("cl", link, fn
        :connect ->
          connect(%{host: "localhost", port: 7000}, request)

        :restart ->
          true
      end)
  end

  defp connect(%{host: host, port: port} = params, request) do
    case :ssl.connect(to_charlist(host), port, [packet: 2], 5000) do
      {:ok, sslsocket} ->
        :ssl.send(sslsocket, <<1::1, 0::15>> <> request)
        sslsocket

      {:error, reason} ->
        Logger.warn("Can't connect #{host}:#{port}: #{inspect(reason)}")
        Process.sleep(10_000)
        connect(params, request)
    end
  end
end
