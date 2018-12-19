defmodule AcariClient.TunCreator do
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :tun_name,
      :ifname
    ]
  end

  def start_link(params) do
    GenServer.start_link(__MODULE__, params, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(_params) do
    :ok = Acari.start_tun("cl", self())
    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:tun_started, {tun_name, ifname}}, state) do
    Logger.debug("Acari client receive :tun_started from #{tun_name}:#{ifname}")
    restart_tunnel()
    {:noreply, %State{state | tun_name: tun_name, ifname: ifname}}
  end

  def handle_cast({:tun_script, _tun_name, script}, %{ifname: ifname} = state) do
    exec_script(script, [{"IFNAME", ifname}])
    {:noreply, state}
  end

  defp exec_script(script, env) do
    IO.inspect({script, env})

    case System.cmd("sh", ["-c", script], stderr_to_stdout: true, env: env) do
      {data, 0} -> data
      {err, code} -> Logger.warn("Script `#{script}` exits with code #{code}, output: #{err}")
    end
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
