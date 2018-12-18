defmodule Acari.SSLink do
  use GenServer, restart: :temporary
  require Logger
  require Acari.Const, as: Const
  alias Acari.Iface
  alias Acari.TunMan

  defmodule State do
    defstruct [
      :name,
      :connector,
      :pid,
      :tun_name,
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
    {:ok, %State{} |> Map.merge(state), {:continue, :init}}
  end

  @impl true
  def handle_continue(
        :init,
        %{name: name, connector: connector, tun_man_pid: tun_man_pid, iface_pid: iface_pid} =
          state
      ) do
    sslsocket = connector.(:connect)
    {:ok, snd_pid} = Acari.SSLinkSnd.start_link(%{sslsocket: sslsocket})
    ifsnd_pid = Iface.get_ifsnd_pid(iface_pid)
    TunMan.set_sslink_snd_pid(tun_man_pid, name, snd_pid)
    schedule_ping()

    {:noreply,
     %{state | pid: self(), sslsocket: sslsocket, snd_pid: snd_pid, ifsnd_pid: ifsnd_pid}}
  end

  @impl true
  def handle_cast(:terminate, state) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, frame}, %{ifsnd_pid: ifsnd_pid} = state) do
    case parse(:erlang.list_to_binary(frame)) do
      {:int, com, data} -> exec_internal(state, com, data)
      {:ext, _com, _data} -> :ok
      packet -> Acari.IfaceSnd.send(ifsnd_pid, packet)
    end

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _sslsocket}, %{name: name, tun_name: tun_name} = state) do
    Logger.info("#{tun_name}: #{name}: Closed")
    {:stop, :shutdown, state}
  end

  def handle_info({:ssl_error, _sslsocket, _reason}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info(:ping, state) do
    send_int_command(state, Const.int_com_echo_request(), to_string(:os.system_time(:second)))
    # Reschedule once more
    schedule_ping()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("SSL: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private

  defp parse(frame) do
    <<com::1, scope::1, val::14, packet::binary>> = frame

    case com do
      0 ->
        packet

      1 ->
        case scope do
          0 -> {:ext, val, packet}
          1 -> {:int, val, packet}
        end
    end
  end

  defp send_int_command(state, com, payload) do
    case :ssl.send(state.sslsocket, <<3::2, com::14>> <> payload) do
      :ok ->
        :ok

      {:error, reason} = res ->
        Logger.warn(
          "#{state.tun_name}: #{state.name}: Can't send to SSL socket: #{inspect(reason)}"
        )

        res
    end
  end

  defp exec_internal(state, com, data) do
    Logger.debug("get int command: #{inspect(%{com: com, data: data})}")

    case com do
      Const.int_com_echo_reply() ->
        :ok

      Const.int_com_echo_request() ->
        send_int_command(state, Const.int_com_echo_reply(), data)

      _ ->
        Logger.warn(
          "#{state.tun_name}: #{state.name}: unexpected int command: #{
            inspect(%{com: com, data: data})
          }"
        )
    end
  end

  defp schedule_ping() do
    Process.send_after(self(), :ping, 5 * 1000)
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
        {:noreply, state}

      {:error, reason} ->
        Logger.warn("Can't send to SSL socket: #{inspect(reason)}")
        {:stop, :shutdown}
    end
  end

  # Client

  def send(sslink_snd_pid, packet, command \\ false) do
    frame = <<0::16>> <> packet
    GenServer.cast(sslink_snd_pid, {:send, frame})
  end
end
