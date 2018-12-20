defmodule Acari.TunMan do
  require Logger
  require Acari.Const, as: Const
  use GenServer
  alias Acari.SSLinkSup
  alias Acari.SSLink
  alias Acari.Iface

  defmodule State do
    defstruct [
      :tun_name,
      :master_pid,
      :tun_sup_pid,
      :ifname,
      :iface_pid,
      :ifsnd_pid,
      :sslink_sup_pid,
      :sslinks,
      current_link: {nil, nil}
    ]
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

    {ifname, ifsnd_pid} = Iface.get_if_info(iface_pid)

    {:ok, sslink_sup_pid} = Supervisor.start_child(tun_sup_pid, SSLinkSup)
    Process.link(sslink_sup_pid)

    GenServer.cast(state.master_pid, {:tun_started, {state.tun_name, ifname}})

    {:noreply,
     %{
       state
       | sslinks: sslinks,
         ifname: ifname,
         iface_pid: iface_pid,
         ifsnd_pid: ifsnd_pid,
         sslink_sup_pid: sslink_sup_pid
     }}
  end

  @impl true
  def handle_cast(
        {:set_sslink_snd_pid, name, pid},
        %State{sslinks: sslinks, iface_pid: iface_pid} = state
      ) do
    true = :ets.update_element(sslinks, name, {3, pid})

    case state.current_link do
      {nil, _} ->
        Iface.set_sslink_snd_pid(iface_pid, pid)
        {:noreply, %State{state | current_link: {name, pid}}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:set_sslink_params, name, params},
        %State{sslinks: sslinks} = state
      ) do
    elem = :ets.lookup_element(sslinks, name, 4)
    true = :ets.update_element(sslinks, name, {4, elem |> Map.merge(params)})

    # get best link
    # TODO if  new letency set

    state = if params[:latency], do: update_best_link(state), else: state

    {:noreply, state}
  end

  def handle_cast({:send_tun_com, com, payload}, %{current_link: {_, sslink_snd_pid}} = state) do
    Acari.SSLinkSnd.send(sslink_snd_pid, <<Const.tun_mask()::2, com::14>>, payload)
    {:noreply, state}
  end

  def handle_cast({:recv_tun_com, com, payload}, state) do
    {:noreply, exec_tun_com(state, com, payload)}
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
        {:reply, :ok, update_best_link(state)}
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

    {:noreply, update_best_link(state)}
  end

  def handle_info(mes, state) do
    Logger.warn("Unexpected info message: #{inspect(mes)}")
    {:noreplay, state}
  end

  # Private
  defp update_best_link(state) do
    {prev_link_name, _} = state.current_link

    case get_best_link(state.sslinks) do
      {^prev_link_name, _} ->
        state

      {link_name, snd_pid} = new_link ->
        Iface.set_sslink_snd_pid(state.iface_pid, snd_pid)
        Logger.debug("#{state.tun_name}: New current link: #{link_name}")
        %State{state | current_link: new_link}

      _ ->
        state
    end
  end

  defp get_best_link(sslinks) do
    case :ets.match_object(sslinks, {:_, :_, :_, :_})
         |> Enum.min_by(fn {_, _, _, parms} -> parms[:latency] end, fn -> nil end) do
      {link, _, snd_pid, %{latency: lat}} when is_number(lat) ->
        {link, snd_pid}

      _ ->
        nil
    end
  end

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

  defp exec_tun_com(state, com, payload) do
    case com do
      Const.exec_script() ->
        GenServer.cast(state.master_pid, {:tun_script, state.tun_name, payload})

      _ ->
        Logger.warn("#{state.tun_name}: Bad command: #{com}")
    end

    state
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

  def recv_tun_com(tun_pid, com, payload) do
    GenServer.cast(tun_pid, {:recv_tun_com, com, payload})
  end

  def exec_remote_script(tun_name, script) do
    GenServer.cast(via(tun_name), {:send_tun_com, Const.exec_script(), script})
  end
end
