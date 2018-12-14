defmodule Acari.TunSup do
  use Supervisor, restart: :temporary

  def start_link(params) do
    tun_name = Map.fetch!(params, :tun_name)
    Supervisor.start_link(__MODULE__, params, name: via(tun_name))
  end

  @impl true
  def init(params) do
    IO.puts("TUN_SUP")
    # List all child processes to be supervised
    children = [
      {Acari.TunMan, params |> Map.put(:tun_sup_pid, self())}
    ]

    opts = [strategy: :one_for_all, name: Acari.Supervisor]
    Supervisor.init(children, opts)
  end

  # Private
  defp via(name) do
    {:via, Registry, {Registry.TunSup, name}}
  end

  # Client

  @sup Acari.TunsSup
  def start_tun(tun_name) when is_binary(tun_name) do
    case DynamicSupervisor.start_child(
           @sup,
           {__MODULE__, %{tun_name: tun_name}}
         ) do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  def start_tun(_), do: {:error, "Tunnel name must be string"}

  def stop_tun(tun_name) do
    case Registry.lookup(Registry.TunSup, tun_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@sup, pid)
      _ -> {:error, "No tunnel '#{tun_name}'"}
    end
  end
end
