defmodule Acari.SSLink do
  use GenServer, restart: :temporary
  require Logger
  require Acari.Const, as: Const
  alias Acari.Iface
  alias Acari.TunMan

  @max_silent_tmo 30 * 1000 * 1000

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
      :sslsocket,
      :latency,
      :echo_reply_tms,
      :echo_reply_wait,
      prio: 0
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

    proto =
      case sslsocket do
        {:sslsocket, _, _} -> :ssl
        _ -> :gen_tcp
      end

    proto_info =
      case proto do
        :gen_tcp ->
          [protocol: :tcp]

        :ssl ->
          case :ssl.connection_information(sslsocket, [:protocol, :selected_cipher_suite]) do
            {:ok, info} when is_list(info) -> info
            _ -> [protocol: :unknown]
          end

        _ ->
          [protocol: :unknown]
      end

    {:ok, snd_pid} =
      Acari.SSLinkSnd.start_link(%{
        sslsocket: sslsocket,
        name: name,
        tun_name: state.tun_name,
        proto: proto
      })

    {_, ifsnd_pid} = Iface.get_if_info(iface_pid)
    TunMan.set_sslink_snd_pid(tun_man_pid, name, snd_pid, proto_info: proto_info)
    schedule_ping(:first)

    {:noreply,
     %{
       state
       | pid: self(),
         sslsocket: sslsocket,
         snd_pid: snd_pid,
         ifsnd_pid: ifsnd_pid,
         echo_reply_tms: :erlang.system_time(:microsecond)
     }}
  end

  @impl true
  def handle_cast(:terminate, state) do
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:ssl, _sslsocket, frame}, state) do
    receive_frame(frame, state)
  end

  def handle_info({:tcp, _sslsocket, frame}, state) do
    receive_frame(frame, state)
  end

  def handle_info({:ssl_closed, _sslsocket}, %{name: name, tun_name: tun_name} = state) do
    Logger.info("#{tun_name}: #{name}: Closed")
    {:stop, :shutdown, state}
  end

  def handle_info({:tcp_closed, _sslsocket}, %{name: name, tun_name: tun_name} = state) do
    Logger.info("#{tun_name}: #{name}: Closed")
    {:stop, :shutdown, state}
  end

  def handle_info({:ssl_error, _sslsocket, reason}, %{name: name, tun_name: tun_name} = state) do
    Logger.error("#{tun_name}: #{name}: SSL error: #{inspect(reason)}")
    {:stop, :shutdown, state}
  end

  def handle_info({:tcp_error, _sslsocket, reason}, %{name: name, tun_name: tun_name} = state) do
    Logger.error("#{tun_name}: #{name}: TCP error: #{inspect(reason)}")
    {:stop, :shutdown, state}
  end

  def handle_info(:ping, %{echo_reply_tms: last_req_tms, echo_reply_wait: wte} = state) do
    tms = :erlang.system_time(:microsecond)

    if tms - last_req_tms < @max_silent_tmo do
      if wte do
        TunMan.set_sslink_params(state.tun_man_pid, state.name, %{latency: tms - last_req_tms})
        Logger.debug("#{state.tun_name}: #{state.name}: No echo reply")
      end

      send_link_command(
        state,
        Const.echo_request(),
        <<tms::64>>
      )

      # Reschedule once more
      schedule_ping()
      {:noreply, %State{state | echo_reply_wait: true}}
    else
      Logger.info("#{state.tun_name}: #{state.name}: Closed(keepalive)")
      {:stop, :shutdown, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warn("SSLink: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp receive_frame(frame, %{ifsnd_pid: ifsnd_pid} = state) do
    state =
      case parse(:erlang.list_to_binary(frame)) do
        {:int, com, data} ->
          exec_link_command(state, com, data)

        {:ext, com, data} ->
          TunMan.recv_tun_com(state.tun_man_pid, com, data)
          state

        packet ->
          Acari.IfaceSnd.send(ifsnd_pid, packet)
          state
      end

    {:noreply, state}
  end

  # Client

  def get_state(pid) do
    GenServer.call(pid, :get_state)
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

  defp send_link_command(state, com, payload) do
    Acari.SSLinkSnd.send(state.snd_pid, <<Const.link_mask()::2, com::14>>, payload)
  end

  defp exec_link_command(state, com, data) do
    # Logger.debug("get int command: #{inspect(%{com: com, data: data})}")

    case com do
      Const.echo_reply() ->
        <<n::64>> = data
        tms = :erlang.system_time(:microsecond)
        latency = tms - n
        TunMan.set_sslink_params(state.tun_man_pid, state.name, %{latency: latency})
        %State{state | latency: latency, echo_reply_tms: tms, echo_reply_wait: nil}

      Const.echo_request() ->
        send_link_command(state, Const.echo_reply(), data)
        state

      Const.prio() ->
        <<prio::8>> = data
        TunMan.set_sslink_params(state.tun_man_pid, state.name, %{prio: prio})
        %State{state | prio: prio}

      _ ->
        Logger.warn(
          "#{state.tun_name}: #{state.name}: unexpected int command: #{
            inspect(%{com: com, data: data})
          }"
        )

        state
    end
  end

  defp schedule_ping(:first) do
    Process.send(self(), :ping, [])
  end

  defp schedule_ping() do
    Process.send_after(self(), :ping, 5000)
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
  def handle_cast({:send, packet}, state = %{sslsocket: sslsocket, proto: proto}) do
    case proto.send(sslsocket, packet) do
      :ok ->
        {:noreply, state}

      {:error, {:badarg, {:packet_to_large, size, _max}}} ->
        Logger.error(
          "#{state.tun_name}: #{state.name}: Can't send to socket: packet_to_large: #{size} bytes"
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("#{state.tun_name}: #{state.name}: Can't send to socket: #{inspect(reason)}")

        {:stop, :shutdown}
    end
  end

  # Client

  def send(sslink_snd_pid, header \\ <<0::16>>, packet) do
    frame = header <> packet
    GenServer.cast(sslink_snd_pid, {:send, frame})
  end
end
