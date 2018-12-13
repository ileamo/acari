defmodule Acari.Iface do
  require Logger
  use GenServer, restart: :temporary

  @moduledoc """
  For IPv4 addresses, beam needs to have privileges to configure interfaces.
  To add cap_net_admin capabilities:
  lubuntu:
  sudo setcap cap_net_admin=ep /usr/lib/erlang/erts-10.1/bin/beam.smp cap_net_admin=ep /bin/ip
  gentoo:
  sudo setcap cap_net_admin=ep /usr/lib64/erlang/erts-10.1.1/bin/beam.smp cap_net_admin=ep /bin/ip
  production:
  sudo setcap cap_net_admin=ep ./erts-10.1.1/bin/beam.smp cap_net_admin=ep /bin/ip
  """

  def start_link(params) do
    GenServer.start_link(__MODULE__, params)
  end

  ## Callbacks
  @impl true
  def init(_params) do
    IO.puts("IFACE started")
    {:ok, ifsocket} = :tuncer.create(<<>>, [:tun, :no_pi, active: true])
    :tuncer.persist(ifsocket, false)
    name = :tuncer.devname(ifsocket)
    {:ok, ifsnd_pid} = Acari.IfaceSnd.start_link(%{ifsocket: ifsocket})

    with {_, 0} <-
           System.cmd(
             "ip",
             ["address", "add", "192.168.123.5/32", "peer", "192.168.123.4", "dev", name],
             stderr_to_stdout: true
           ),
         :ok = if_up(name) do
      Logger.info("IFACE created and UP")

      state = %{
        ifsocket: ifsocket,
        ifname: name,
        ifsnd_pid: ifsnd_pid,
        up: true
      }

      {:ok, state}
    else
      {err, _} ->
        Logger.error("IFACE not started: #{inspect(err)}")
        :tuncer.destroy(ifsocket)
        {:stop, err}
    end
  end

  @impl true
  def handle_cast({:set_sslink_snd_pid, sslink_snd_pid}, state) do
    {:noreply, state |> Map.put(:sslink_snd_pid, sslink_snd_pid)}
  end

  @impl true
  def handle_call(:get_ifsnd_pid, _from, %{ifsnd_pid: ifsnd_pid} = state) do
    {:reply, ifsnd_pid, state}
  end

  @impl true
  def handle_info(
        {:tuntap, _pid, packet},
        state = %{sslink_snd_pid: sslink_snd_pid}
      )
      when is_pid(sslink_snd_pid) do
    case Process.alive?(sslink_snd_pid) do
      true ->
        Logger.debug("IFACE receive #{byte_size(packet)}")
        Acari.SSLinkSnd.send(sslink_snd_pid, packet)
        {:noreply, state}

      _ ->
        {:noreply, %{state | sslink_snd_pid: nil}}
    end
  end

  def handle_info({:tuntap, _pid, _packet}, state) do
    Logger.debug("IFACE: No link to send")
    # if_down(ifname)
    {:noreply, %{state | up: false}}
  end

  def handle_info({:tuntap_error, _pid, reason}, state) do
    Logger.error("IFACE: #{inspect(reason)}")
    # GenServer.cast(pid, :terminate)
    {:stop, :shutdown, state}
  end

  def handle_info(msg, state) do
    Logger.warn("IFACE: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # client
  def set_sslink_snd_pid(iface_pid, sslink_snd_pid) do
    GenServer.cast(iface_pid, {:set_sslink_snd_pid, sslink_snd_pid})
  end

  def get_ifsnd_pid(iface_pid) do
    GenServer.call(iface_pid, :get_ifsnd_pid)
  end

  defp if_up(ifname), do: if_set_admstate(ifname, "up")
  defp if_down(ifname), do: if_set_admstate(ifname, "down")

  defp if_set_admstate(ifname, admstate) do
    {_, 0} = System.cmd("ip", ["link", "set", ifname, admstate], stderr_to_stdout: true)
    :ok
  end
end

defmodule Acari.IfaceSnd do
  require Logger
  use GenServer

  def start_link(params) do
    GenServer.start_link(__MODULE__, params)
  end

  ## Callbacks
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send, packet}, state = %{ifsocket: ifsocket}) do
    :tuncer.send(ifsocket, packet)
    Logger.debug("IFACE send #{byte_size(packet)} bytes")
    {:noreply, state}
  end

  # Client

  def send(ifsnd_pid, packet) do
    GenServer.cast(ifsnd_pid, {:send, packet})
  end
end
