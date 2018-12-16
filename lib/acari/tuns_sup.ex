defmodule Acari.TunsSup do
  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    IO.puts("TUNS SUP")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Client

  def start_tun(tun_name) when is_binary(tun_name) do
    case DynamicSupervisor.start_child(
           __MODULE__,
           {Acari.TunSup, %{tun_name: tun_name}}
         ) do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  def start_tun(_), do: {:error, "Tunnel name must be string"}

  def stop_tun(tun_name) do
    case Registry.lookup(Registry.TunSup, tun_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Acari.TunsSup, pid)
      _ -> {:error, "No tunnel '#{tun_name}'"}
    end
  end
end
