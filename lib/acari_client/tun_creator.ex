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

    :ok = Acari.start_tun("tun")

    :ok = Acari.add_link("tun", "link", fn -> connect("localhost", 7000) end)

    {:ok, state}
  end

  defp connect(host, port, params \\ []) do
    case :ssl.connect(to_charlist(host), port, [packet: 2], 5000) do
      {:ok, sslsocket} ->
        :ssl.send(sslsocket, "NSG1700_1812000999")
        sslsocket

      {:error, reason} ->
        Logger.warn("Can't connect #{host}:#{port}: #{inspect(reason)}")
        Process.sleep(10_000)
        connect(host, port, params)
    end
  end
end
