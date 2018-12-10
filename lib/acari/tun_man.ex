defmodule Acari.TunMan do
  require Logger
  use GenServer
  alias Acari.SSLinkSup
  alias Acari.SSLink
  alias Acari.Iface

  defmodule State do
    defstruct [:tun_sup_pid, :iface_pid, :sslinks]
  end

  def start_link(params) do
    GenServer.start_link(__MODULE__, params)
  end

  ## Callbacks
  @impl true
  def init(%{tun_sup_pid: tun_sup_pid} = params) when is_pid(tun_sup_pid) do
    IO.puts("START TUN_MAN")
    IO.inspect(params)
    {:ok, %State{tun_sup_pid: tun_sup_pid}, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, %{tun_sup_pid: tun_sup_pid} = state) do
    {:ok, iface_pid} = Supervisor.start_child(tun_sup_pid, Iface)
    Process.link(iface_pid)

    sslinks = :ets.new(:sslinks, [:set, :protected, :named_table])
    Process.flag(:trap_exit, true)

    for name <- ["Link_A", "Link_B"] do
      update_sslink(sslinks, name, %{})
    end

    {:noreply, %{state | sslinks: sslinks, iface_pid: iface_pid}}
  end

  @impl true
  def handle_cast({:set_sslink_snd_pid, name, pid}, %State{sslinks: sslinks} = state) do
    IO.puts("CAST SENDER PID")
    true = :ets.update_element(sslinks, name, {3, pid})
    Iface.set_lisender_pid(Iface, pid)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_all_links, _from, %State{sslinks: sslinks} = state) do
    res = :ets.match(sslinks, {:"$1", :"$2", :"$3", :"$4"})
    {:reply, res, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %State{iface_pid: pid} = state) do
    {:stop, {:iface_exit, reason}, state}
  end

  def handle_info({:EXIT, pid, _reason}, %State{sslinks: sslinks} = state) do
    [[name, params]] = :ets.match(sslinks, {:"$1", pid, :_, :"$2"})
    update_sslink(sslinks, name, params)
    {:noreply, state}
  end

  # Private
  defp update_sslink(sslinks, name, params) do
    {:ok, pid} =
      SSLinkSup.start_link_worker(SSLinkSup, {SSLink, %{name: name, tun_man_pid: self()}})

    true = Process.link(pid)
    true = :ets.insert(sslinks, {name, pid, nil, params})
  end

  # Client
  def get_all_links() do
    GenServer.call(__MODULE__, :get_all_links)
  end

  def set_sslink_snd_pid(tun_pid, name, pid) do
    GenServer.cast(tun_pid, {:set_sslink_snd_pid, name, pid})
  end
end
