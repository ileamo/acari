defmodule Acari.TunMan do
  require Logger
  use GenServer
  alias Acari.SSLinkSup
  alias Acari.SSLink
  alias Acari.Iface

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(_state) do
    Logger.debug("START LINK MANAGER")
    links = :ets.new(:links, [:set, :protected, :named_table])
    Process.flag(:trap_exit, true)

    for name <- ["Link_A", "Link_B"] do
      {:ok, pid} = SSLinkSup.start_link_worker(SSLinkSup, {SSLink, %{name: name}})
      true = Process.link(pid)
      true = :ets.insert_new(links, {name, pid, nil, %{}})
    end

    {:ok, %{links: links}}
  end

  @impl true
  def handle_cast({:set_link_sender_pid, name, pid}, %{links: links} = state) do
    true = :ets.update_element(links, name, {3, pid})
    Iface.set_lisender_pid(Iface, pid)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_all_links, _from, %{links: links} = state) do
    res = :ets.match(links, {:"$1", :"$2", :"$3", :"$4"})
    {:reply, res, state}
  end

  # Client
  def get_all_links() do
    GenServer.call(__MODULE__, :get_all_links)
  end

  def set_link_sender_pid(name, pid) do
    GenServer.cast(__MODULE__, {:set_link_sender_pid, name, pid})
  end
end
