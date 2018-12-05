defmodule Acari.Link do
  require Logger
  use GenServer, restart: :temporary

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  ## Callbacks
  @impl true
  def init(state) do
    Logger.debug("START LINK")
    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, %{iface_pid: iface_pid} = state) do
    Logger.debug("LINK CONTINUE")

    case :ssl.connect('localhost', 7000, [packet: 2], 5000) do
      {:ok, sslsocket} ->
        {:ok, sender_pid} = Acari.LinkSender.start_link(%{sslsocket: sslsocket})
        Acari.Iface.set_link_sender_pid(iface_pid, self(), sender_pid)

        {:noreply,
         state |> Map.merge(%{pid: self(), sslsocket: sslsocket, sender_pid: sender_pid})}

      {:error, reason} ->
        Logger.error("Can't connect: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_cast(:terminate, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, data}, state = %{iface_sender_pid: iface_sender_pid}) do
    Logger.debug("SSL RECV #{length(data)} bytes")
    GenServer.cast(iface_sender_pid, {:send, data})

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _sslsocket}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _sslsocket, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Link server: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Client
  def start_child(param) do
    DynamicSupervisor.start_child(
      Acari.LinkSupervisor,
      child_spec(param)
    )
  end
end

defmodule Acari.LinkSender do
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
    :ssl.send(sslsocket, packet)
    Logger.debug("SEND TO SSL #{byte_size(packet)} bytes")
    {:noreply, state}
  end
end
