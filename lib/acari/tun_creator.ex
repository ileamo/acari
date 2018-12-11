defmodule Acari.TunCreator do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    IO.puts("TUN_CREATOR")

    :ok = Acari.start_tun("tun")
    :ok = Acari.add_link("tun", %{name: "link"})

    # {:ok, _} = Acari.start_tun()

    {:ok, state}
  end
end
