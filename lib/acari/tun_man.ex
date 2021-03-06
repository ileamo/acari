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
      :send_peer_started,
      :peer_params,
      :iface_conf,
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

    {:ok, iface_pid} =
      Supervisor.start_child(
        tun_sup_pid,
        {Iface, %{tun_name: state.tun_name, ifname: state.iface_conf[:name],
        tap: state.iface_conf[:tap]}}
      )

    Process.link(iface_pid)

    {ifname, ifsnd_pid} = Iface.get_if_info(iface_pid)

    {:ok, sslink_sup_pid} = Supervisor.start_child(tun_sup_pid, SSLinkSup)
    Process.link(sslink_sup_pid)

    state = %{
      state
      | sslinks: sslinks,
        ifname: ifname,
        iface_pid: iface_pid,
        ifsnd_pid: ifsnd_pid,
        sslink_sup_pid: sslink_sup_pid
    }

    GenServer.cast(state.master_pid, {:tun_started, state})

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:set_sslink_snd_pid, name, pid, opts},
        %State{sslinks: sslinks, iface_pid: iface_pid} = state
      ) do
    true = :ets.update_element(sslinks, name, {3, pid})
    sslink_opened(state, name, opts)

    case state.current_link do
      {nil, _} ->
        Iface.set_sslink_snd_pid(iface_pid, pid)

        state =
          case state.send_peer_started do
            true ->
              state

            _ ->
              send_tun_com(self(), Const.peer_started(), "")
              %State{state | send_peer_started: true}
          end

        {:noreply, %State{state | current_link: {name, pid}}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:set_sslink_params, name, params},
        %State{sslinks: sslinks} = state
      ) do
    state =
      case :ets.lookup(sslinks, name) do
        [{_, _, _, elem}] ->
          true = :ets.update_element(sslinks, name, {4, elem |> Map.merge(params)})
          if params[:latency], do: update_best_link(state), else: state

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_cast({:send_tun_com, com, payload}, %{current_link: {_, sslink_snd_pid}} = state) do
    Logger.debug("#{state.tun_name}: Send com #{com} pid = #{inspect(sslink_snd_pid)}")

    case is_pid(sslink_snd_pid) and Process.alive?(sslink_snd_pid) do
      true ->
        Acari.SSLinkSnd.send(sslink_snd_pid, Const.hd_tun_com(com), payload)

      _ ->
        Acari.Iface.redirect(state.tun_name, Const.hd_tun_com(com), payload)
    end

    {:noreply, state}
  end

  def handle_cast({:send_all_link_com, com, payload}, %State{sslinks: sslinks} = state) do
    Logger.debug("#{state.tun_name}: Send com to all link #{com}: #{inspect(payload)}")

    :ets.foldl(
      fn {_, _, snd_pid, _}, _ ->
        Acari.SSLinkSnd.send(snd_pid, <<Const.link_mask()::2, com::14>>, payload)
      end,
      nil,
      sslinks
    )

    {:noreply, state}
  end

  def handle_cast({:recv_tun_com, com, payload}, state) do
    Logger.debug("#{state.tun_name}: Receive com #{com}")
    {:noreply, exec_tun_com(state, com, payload)}
  end

  def handle_cast(mes, state) do
    Logger.error(" Bad message: #{inspect(mes)} #{inspect(state)}")
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
        {:reply, :ok, update_best_link(state)}
    end
  end

  def handle_call(:get_all_links, _from, %State{sslinks: sslinks} = state) do
    res = :ets.match(sslinks, {:"$1", :_, :_, :"$2"})
    {:reply, res, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(request, _from, state) do
    {:reply, {:error, "Bad request #{inspect(request)}"}, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %State{iface_pid: pid} = state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, pid, _reason}, %State{sslink_sup_pid: pid} = state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, pid, _reason}, %State{sslinks: sslinks} = state) do
    name =
      case :ets.match(sslinks, {:"$1", pid, :_, :"$2"}) do
        [[name, %{restart: restart}]] when restart == 0 ->
          :ets.delete(sslinks, name)
          name

        [[name, %{connector: connector, restart: timestamp}]] ->
          # remove latency
          elem = :ets.lookup_element(sslinks, name, 4)
          true = :ets.update_element(sslinks, name, {4, elem |> Map.delete(:latency)})

          if((delta = :erlang.system_time(:second) - timestamp) >= 10) do
            update_sslink(state, name, connector)
          else
            Process.send_after(self(), {:EXIT, pid, :restart}, (10 - delta) * 1000)
          end

          name

        [] ->
          nil
      end

    sslink_closed(state, name, num: :ets.info(sslinks, :size))

    {:noreply, update_best_link(state)}
  end

  def handle_info(mes, state) do
    Logger.warn("Unexpected info message: #{inspect(mes)}")
    {:noreply, state}
  end

  # Private
  defp update_best_link(state) do
    {prev_link_name, prev_pid} = state.current_link

    case get_best_link(state.sslinks) do
      {^prev_link_name, ^prev_pid} ->
        state

      {_link_name, snd_pid} = new_link ->
        Iface.set_sslink_snd_pid(state.iface_pid, snd_pid)
        # Logger.debug("#{state.tun_name}: New current link: #{link_name}")
        %State{state | current_link: new_link}

      _ ->
        # Logger.debug("#{state.tun_name}: New current link: <NO LINK>")
        %State{state | current_link: {nil, nil}}
    end
  end

  defp get_best_link(sslinks) do
    :ets.foldl(
      fn {name, _pid, snd_pid, params}, {_best_link, best_params} = best ->
        prio_new = params[:prio] || 0
        prio_bst = best_params[:prio] || 0

        cond do
          !params[:latency] -> best
          prio_new > prio_bst ->
            {{name, snd_pid}, %{prio: prio_new, latency: params[:latency]}}

          prio_new == prio_bst and params[:latency] < best_params[:latency] ->
            {{name, snd_pid}, %{prio: prio_new, latency: params[:latency]}}

          true ->
            best
        end
      end,
      {nil, %{prio: -1}},
      sslinks
    )
    |> elem(0)
  end

  defp update_sslink(
         %{
           tun_name: tun_name,
           sslinks: sslinks,
           iface_pid: iface_pid,
           sslink_sup_pid: sslink_sup_pid
         } = _state,
         name,
         connector
       ) do
    # true = Process.alive?(sslink_sup_pid)
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
      Const.master_mes() ->
        GenServer.cast(state.master_pid, {:master_mes, state.tun_name, payload})

      Const.master_mes_plus() ->
        [main | attach] = decode_mes_plus(payload)
        GenServer.cast(state.master_pid, {:master_mes_plus, state.tun_name, main, attach})

      Const.peer_started() ->
        GenServer.cast(state.master_pid, {:peer_started, state.tun_name})

      Const.json_req() ->
        exec_json_req(state, payload)

      _ ->
        Logger.warn("#{state.tun_name}: Bad command: #{com}")
    end

    state
  end

  defp decode_mes_plus(payload, list \\ []) do
    case payload do
      <<len::16, first::binary-size(len), rest::binary>> ->
        decode_mes_plus(rest, [first | list])

      _ ->
        list |> Enum.reverse()
    end
  end

  defp exec_json_req(state, json) do
    {:ok, %{"method" => method, "params" => params}} = Jason.decode(json)

    exec_tun_method(state, method, params)
  end

  defp exec_tun_method(state, method, _) do
    Logger.error("Unknown method #{method}")
    state
  end

  defp via(name) do
    {:via, Registry, {Registry.TunMan, name}}
  end

  defp sslink_opened(state, name, opts) do
    GenServer.cast(state.master_pid, {:sslink_opened, state.tun_name, name, opts})
  end

  defp sslink_closed(state, name, opts) do
    GenServer.cast(state.master_pid, {:sslink_closed, state.tun_name, name, opts})
  end

  # Client
  def add_link(tun_name, link_name, connector) do
    case Registry.lookup(Registry.TunMan, tun_name) do
      [{pid, _}] ->
        GenServer.call(pid, {:add_link, link_name, connector}, 60 * 1000)

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

  def get_state(tun_name) do
    GenServer.call(via(tun_name), :get_state)
  end

  def set_sslink_snd_pid(tun_pid, name, pid, opts \\ []) do
    GenServer.cast(tun_pid, {:set_sslink_snd_pid, name, pid, opts})
  end

  def set_sslink_params(tun_pid, name, params) do
    GenServer.cast(tun_pid, {:set_sslink_params, name, params})
  end

  def recv_tun_com(tun_pid, com, payload) do
    GenServer.cast(tun_pid, {:recv_tun_com, com, payload})
  end

  def send_tun_alive_request(tun_name) do
    tms = :erlang.system_time(:microsecond)
    send_tun_com(tun_name, Const.tun_alive_request(), <<tms::64>>)
  end

  def send_json_request(tun_name, payload) do
    {:ok, json} = Jason.encode(payload)
    send_tun_com(tun_name, Const.json_req(), json)
  end

  def send_master_mes(tun_name, payload) do
    {:ok, json} = Jason.encode(payload)
    GenServer.cast(via(tun_name), {:send_tun_com, Const.master_mes(), json})
  end

  def send_master_mes_plus(tun_name, main, attach \\ []) do
    {:ok, json} = Jason.encode(main)

    payload =
      [json | attach] |> Enum.reduce("", fn mes, acc -> acc <> <<byte_size(mes)::16>> <> mes end)

    GenServer.cast(via(tun_name), {:send_tun_com, Const.master_mes_plus(), payload})
  end

  def send_tun_com(pid, com, payload) when is_pid(pid) do
    GenServer.cast(pid, {:send_tun_com, com, payload})
  end

  def send_tun_com(tun_name, com, payload) do
    GenServer.cast(via(tun_name), {:send_tun_com, com, payload})
  end

  def send_all_link_com(tun_name, com, payload) do
    GenServer.cast(via(tun_name), {:send_all_link_com, com, payload})
  end
end
