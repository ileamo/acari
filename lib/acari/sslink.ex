defmodule Acari.SSLink do
  require Logger
  use GenServer, restart: :temporary
  alias Acari.Iface
  alias Acari.TunMan

  defmodule State do
    defstruct [
      :name,
      :connector,
      :pid,
      :tun_man_pid,
      :snd_pid,
      :iface_pid,
      :ifsnd_pid,
      :sslsocket
    ]
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  ## Callbacks
  @impl true
  def init(%{name: name, tun_man_pid: tun_man_pid, iface_pid: iface_pid} = state)
      when is_binary(name) and is_pid(tun_man_pid) and is_pid(iface_pid) do
    IO.puts("START SSLINK #{name}")
    {:ok, %State{} |> Map.merge(state), {:continue, :init}}
  end

  @impl true
  def handle_continue(
        :init,
        %{name: name, connector: connector, tun_man_pid: tun_man_pid, iface_pid: iface_pid} =
          state
      ) do
    sslsocket = connector.()
    {:ok, snd_pid} = Acari.SSLinkSnd.start_link(%{sslsocket: sslsocket})
    ifsnd_pid = Iface.get_ifsnd_pid(iface_pid)
    TunMan.set_sslink_snd_pid(tun_man_pid, name, snd_pid)

    {:noreply,
     %{state | pid: self(), sslsocket: sslsocket, snd_pid: snd_pid, ifsnd_pid: ifsnd_pid}}
  end

  @impl true
  def handle_cast(:terminate, state) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, data}, state = %{ifsnd_pid: ifsnd_pid}) do
    Logger.debug("SSL recv #{length(data)} bytes")
    GenServer.cast(ifsnd_pid, {:send, data})

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _sslsocket}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:ssl_error, _sslsocket, _reason}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info(msg, state) do
    Logger.warn("SSL: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end
end

defmodule Acari.SSLinkSnd do
  require Logger
  use GenServer, restart: :temporary

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  ## Callbacks
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send, packet}, state = %{sslsocket: sslsocket}) do
    case :ssl.send(sslsocket, packet) do
      :ok ->
        Logger.debug("SSL send #{byte_size(packet)} bytes")
        {:noreply, state}

      {:error, reason} ->
        Logger.warn("Can't send to SSL socket: #{inspect(reason)}")
        {:stop, :shutdown}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warn("SSL SENDER info: #{inspect(msg)}")
    {:noreply, state}
  end
end
