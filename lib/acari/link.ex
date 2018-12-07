defmodule Acari.Link do
  require Logger
  use GenServer, restart: :temporary
  alias Acari.Iface
  alias Acari.LinkManager

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  ## Callbacks
  @impl true
  def init(state) do
    Logger.debug("START LINK #{inspect(state)}")
    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, %{name: name} = state) do
    sslsocket = connect(%{"host" => 'localhost', "port" => 7000})
    {:ok, sender_pid} = Acari.LinkSender.start_link(%{sslsocket: sslsocket})
    ifsender_pid = Iface.get_ifsender_pid()
    LinkManager.set_link_sender_pid(name, sender_pid)

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
    Logger.debug("SSL recv #{length(data)} bytes")
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
    Logger.warn("SSL: unknown message: #{inspect(msg)}")
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
