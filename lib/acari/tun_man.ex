defmodule Acari.TunMan do
  require Logger
  use GenServer
  alias Acari.SSLinkSup
  alias Acari.SSLink
  alias Acari.Iface

  defmodule State do
    defstruct [:tun_name, :master_pid, :tun_sup_pid, :iface_pid, :sslink_sup_pid, :sslinks]
  end

  def start_link(params) do
    tun_name = Map.fetch!(params, :tun_name)
    GenServer.start_link(__MODULE__, params, name: via(tun_name))
  end

  ## Callbacks
  @impl true
  def init(%{tun_sup_pid: tun_sup_pid} = params) when is_pid(tun_sup_pid) do
    {:ok, %State{} |> Map.merge(params), {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, %{tun_sup_pid: tun_sup_pid} = state) do
    Logger.info("#{state.tun_name}: Tunnel (re)started")
    sslinks = :ets.new(:sslinks, [:set, :protected])
    Process.flag(:trap_exit, true)

    {:ok, iface_pid} = Supervisor.start_child(tun_sup_pid, {Iface, %{tun_name: state.tun_name}})
    Process.link(iface_pid)

    {:ok, sslink_sup_pid} = Supervisor.start_child(tun_sup_pid, SSLinkSup)
    Process.link(sslink_sup_pid)

    GenServer.cast(state.master_pid, {:tun_started, state.tun_name})

    {:noreply, %{state | sslinks: sslinks, iface_pid: iface_pid, sslink_sup_pid: sslink_sup_pid}}
  end

  @impl true
  def handle_cast(
        {:set_sslink_snd_pid, name, pid},
        %State{sslinks: sslinks, iface_pid: iface_pid} = state
      ) do
    true = :ets.update_element(sslinks, name, {3, pid})
    Iface.set_sslink_snd_pid(iface_pid, pid)
    {:noreply, state}
  end

  def handle_cast(
        {:set_sslink_params, name, params},
        %State{sslinks: sslinks} = state
      ) do
    elem = :ets.lookup_element(sslinks, name, 4)
    true = :ets.update_element(sslinks, name, {4, elem |> Map.merge(params)})
    {:noreply, state}
  end

  @impl true
  def handle_call({:add_link, name, connector}, _from, %{sslinks: sslinks} = state)
      when is_binary(name) do
    case :ets.member(sslinks, name) do
      true ->
        {:reply, {:error, "Already exist"}, state}

      _ ->
        pid = update_sslink(state, name, connector)
        {:reply, {:ok, pid}, state}
    end
  end

  def handle_call({:add_link, _, _}, _from, state) do
    {:reply, {:error, "Link name must be string"}, state}
  end

  def handle_call(
        {:del_link, name},
        _from,
        %{sslinks: sslinks, sslink_sup_pid: sslink_sup_pid} = state
      ) do
    case :ets.lookup(sslinks, name) do
      [] ->
        {:reply, {:error, "No link"}, state}

      [{_, pid, _, _}] ->
        :ets.delete(sslinks, name)
        DynamicSupervisor.terminate_child(sslink_sup_pid, pid)
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_all_links, _from, %State{sslinks: sslinks} = state) do
    res = :ets.match_object(sslinks, {:_, :_, :_, :_})
    {:reply, res, state}
  end

  def handle_call(request, _from, state) do
    {:reply, {:error, "Bad request #{inspect(request)}"}, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %State{iface_pid: pid} = state) do
    {:stop, {:iface_exit, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %State{sslink_sup_pid: pid} = state) do
    {:stop, {:sslink_sup_exit, reason}, state}
  end

  def handle_info({:EXIT, pid, _reason}, %State{sslinks: sslinks} = state) do
    case :ets.match(sslinks, {:"$1", pid, :_, :"$2"}) do
      [[name, %{restart: restart}]] when restart == 0 ->
        :ets.delete(sslinks, name)

      [[name, %{connector: connector, restart: timestamp}]] ->
        if((delta = :erlang.system_time(:second) - timestamp) >= 10) do
          update_sslink(state, name, connector)
        else
          Process.send_after(self(), {:EXIT, pid, :restart}, (10 - delta) * 1000)
        end

      [] ->
        nil
    end

    {:noreply, state}
  end

  def handle_info(mes, state) do
    Logger.warn("Unexpected info message: #{inspect(mes)}")
    {:noreplay, state}
  end

  # Private
  defp update_sslink(
         %{
           tun_name: tun_name,
           sslinks: sslinks,
           iface_pid: iface_pid,
           sslink_sup_pid: sslink_sup_pid
         },
         name,
         connector
       ) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        sslink_sup_pid,
        {SSLink,
         %{
           name: name,
           connector: connector,
           tun_name: tun_name,
           tun_man_pid: self(),
           iface_pid: iface_pid
         }}
      )

    true = Process.link(pid)

    true =
      :ets.insert(
        sslinks,
        {name, pid, nil,
         %{
           connector: connector,
           restart: if(connector.(:restart), do: :erlang.system_time(:second), else: 0)
         }}
      )

    pid
  end

  defp via(name) do
    {:via, Registry, {Registry.TunMan, name}}
  end

  # Client
  def add_link(tun_name, link_name, connector) do
    case Registry.lookup(Registry.TunMan, tun_name) do
      [{pid, _}] ->
        GenServer.call(pid, {:add_link, link_name, connector})

      _ ->
        Logger.error("Add link: No such tunnel: #{tun_name}")
        {:error, :no_tunhel}
    end
  end

  def del_link(tun_name, link_name) do
    GenServer.call(via(tun_name), {:del_link, link_name})
  end

  def get_all_links(tun_name) do
    GenServer.call(via(tun_name), :get_all_links)
  end

  def set_sslink_snd_pid(tun_pid, name, pid) do
    GenServer.cast(tun_pid, {:set_sslink_snd_pid, name, pid})
  end

  def set_sslink_params(tun_pid, name, params) do
    GenServer.cast(tun_pid, {:set_sslink_params, name, params})
  end
end
