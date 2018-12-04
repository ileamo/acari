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
    GenServer.start_link(__MODULE__, params)
  end

  ## Callbacks
  @impl true
  def init(_params) do
    Logger.debug("START IFACE")
    {:ok, ref} = :tuncer.create(<<>>, [:tun, :no_pi, active: true])
    :tuncer.persist(ref, false)
    name = :tuncer.devname(ref)

    with {_, 0} <-
           System.cmd(
             "ip",
             ["address", "add", "192.168.123.5/32", "peer", "192.168.123.4", "dev", name],
             stderr_to_stdout: true
           ),
         {_, 0} <- System.cmd("ip", ["link", "set", name, "up"], stderr_to_stdout: true) do
      Logger.debug("Create iface #{name}")
      state = %{ifsocket: ref, ifname: name, links_list: []}
      {:ok, state}
    else
      {err, _} ->
        Logger.error(err)
        :tuncer.destroy(ref)
        {:stop, err}
    end
  end

  @impl true
  def handle_call({:send, packet}, _from, state = %{ifsocket: ifsocket}) do
    Logger.debug("IFACE handle_call, packet: #{inspect(packet)}")
    :tuncer.send(ifsocket, to_string(packet))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tuntap, _pid, packet}, state = %{links_list: [%{pid: link_pid} | _]}) do
    Logger.debug("Iface #{state[:ifname]}: receive #{byte_size(packet)}")
    GenServer.call(link_pid, {:send, packet})
    {:noreply, state}
  end

  def handle_info({:tuntap_error, _pid, reason}, state = %{links_list: links_list}) do
    Logger.error("Iface #{state[:ifname]}: #{inspect(reason)}")
    links_list |> Enum.each(fn %{pid: pid} -> GenServer.cast(pid, :terminate) end)
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Iface server: unknown message: #{inspect(msg)}")
    {:noreply, state}
  end
end
