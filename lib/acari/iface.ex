defmodule Acari.Iface do
  require Logger
  use GenServer

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
    GenServer.start_link(__MODULE__, params, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(_params) do
    Logger.debug("START IFACE")
    {:ok, ifsocket} = :tuncer.create(<<>>, [:tun, :no_pi, active: true])
    :tuncer.persist(ifsocket, false)
    name = :tuncer.devname(ifsocket)
    {:ok, ifsender_pid} = Acari.IfaceSender.start_link(%{ifsocket: ifsocket})

    with {_, 0} <-
           System.cmd(
             "ip",
             ["address", "add", "192.168.123.5/32", "peer", "192.168.123.4", "dev", name],
             stderr_to_stdout: true
           ),
         :ok = if_up(name) do
      Logger.info("Iface #{name} created and UP")

      state = %{
        ifsocket: ifsocket,
        ifname: name,
        ifsender_pid: ifsender_pid,
        up: true,
        links_list: []
      }

      {:ok, state}
    else
      {err, _} ->
        Logger.error(err)
        :tuncer.destroy(ifsocket)
        {:stop, err}
    end
  end

  @impl true
  def handle_cast({:set_link_sender_pid, _pid, sender_pid}, %{links_list: links_list} = state) do
    links_list = [%{sender_pid: sender_pid} | links_list]
    {:noreply, state |> Map.put(:links_list, links_list)}
  end

  @impl true
  def handle_call(:get_ifsender_pid, _from, %{ifsender_pid: ifsender_pid} = state) do
    {:reply, ifsender_pid, state}
  end

  @impl true
  def handle_info(
        {:tuntap, _pid, packet},
        state = %{links_list: [%{sender_pid: link_sender_pid} | _]}
      ) do
    Logger.debug("Iface #{state[:ifname]}: receive #{byte_size(packet)}")
    GenServer.cast(link_sender_pid, {:send, packet})
    {:noreply, state}
  end

  def handle_info(
        {:tuntap, _pid, _packet},
        %{ifname: ifname} = state
      ) do
    Logger.debug("Iface #{state[:ifname]}: No link to send")
    # if_down(ifname)
    {:noreply, %{state | up: false}}
  end

  def handle_info({:tuntap_error, _pid, reason}, state = %{links_list: links_list}) do
    Logger.error("Iface #{state[:ifname]}: #{inspect(reason)}")
    links_list |> Enum.each(fn %{sender_pid: pid} -> GenServer.cast(pid, :terminate) end)
    {:stop, :shutdown, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Iface server: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # client
  def set_link_sender_pid(iface_pid, link_pid, link_sender_pid) do
    GenServer.cast(iface_pid, {:set_link_sender_pid, link_pid, link_sender_pid})
  end

  def get_ifsender_pid() do
    GenServer.call(__MODULE__, :get_ifsender_pid)
  end

  defp if_up(ifname), do: if_set_admstate(ifname, "up")
  defp if_down(ifname), do: if_set_admstate(ifname, "down")

  defp if_set_admstate(ifname, admstate) do
    {_, 0} = System.cmd("ip", ["link", "set", ifname, admstate], stderr_to_stdout: true)
    :ok
  end
end

defmodule Acari.IfaceSender do
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
    :tuncer.send(ifsocket, to_string(packet))
    Logger.debug("IFACE SEND #{length(packet)} bytes")
    {:noreply, state}
  end
end
