defmodule Acari.Link do
  require Logger
  use GenServer, restart: :temporary

  def start_link(sock) do
    GenServer.start_link(__MODULE__, sock)
  end

  ## Callbacks
  @impl true
  def init(state) do
    Logger.debug("START LINK")
    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    Logger.debug("LINK CONTINUE")

    case :ssl.connect('10.0.10.155', 7000, [packet: 2], 5000) do
      {:ok, s} ->
        {:noreply, state |> Map.merge(%{pid: self(), sslsocket: s})}

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
  def handle_call({:send, packet}, _from, state = %{sslsocket: sslsocket}) do
    Logger.debug("LINK CALL")
    :ssl.send(sslsocket, packet)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, data}, state = %{iface_pid: iface_pid}) do
    Logger.debug("Receive data: #{inspect(data)}")
    GenServer.call(iface_pid, {:send, data})

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
