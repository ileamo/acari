defmodule Acari.TunCreator do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    IO.puts("TUN_CREATOR")
    DynamicSupervisor.start_child(Acari.TunsSup, Acari.TunSup)
    {:ok, state}
  end
end
