defmodule Acari.Link do
  require Logger
  use GenServer
  alias Acari.Iface

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
  def handle_continue(:init, state) do
    Logger.debug("LINK CONTINUE")

    sslsocket = connect(%{"host" => 'localhost', "port" => 7000})
    {:ok, sender_pid} = Acari.LinkSender.start_link(%{sslsocket: sslsocket})
    ifsender_pid = Iface.get_ifsender_pid()
    Iface.set_link_sender_pid(Iface, self(), sender_pid)

    {:noreply,
     state
     |> Map.merge(%{
       pid: self(),
       sslsocket: sslsocket,
       sender_pid: sender_pid,
       ifsender_pid: ifsender_pid
     })}
  end

  defp connect(%{"host" => host, "port" => port} = parms) do
    case :ssl.connect(to_charlist(host), port, [packet: 2], 5000) do
      {:ok, sslsocket} ->
        sslsocket

      {:error, reason} ->
        Logger.warn("Can't connect #{host}:#{port}: #{inspect(reason)}")
        Process.sleep(10_000)
        connect(parms)
    end
  end

  @impl true
  def handle_cast(:terminate, state) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, data}, state = %{ifsender_pid: ifsender_pid}) do
    Logger.debug("SSL RECV #{length(data)} bytes")
    GenServer.cast(ifsender_pid, {:send, data})

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _sslsocket}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:ssl_error, _sslsocket, _reason}, state) do
    {:stop, :shutdown, state}
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
    case :ssl.send(sslsocket, packet) do
      :ok ->
        Logger.debug("SEND TO SSL(#{inspect(self())}) #{byte_size(packet)} bytes")
        {:noreply, state}

      {:error, reason} ->
        Logger.warn("Can't send to SSL socket: #{inspect(reason)}")
        {:stop, :shutdown}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warn("Link sender info: #{inspect(msg)}")
    {:noreply, state}
  end
end
