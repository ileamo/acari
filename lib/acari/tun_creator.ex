defmodule Acari.TunCreator do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    IO.puts("TUN_CREATOR")

    {:ok, _} =
      DynamicSupervisor.start_child(
        Acari.TunsSup,
        {Acari.TunSup, %{sslinks: [%{name: "Link_A"}, %{name: "Link_B"}]}}
      )

    {:ok, _} =
      DynamicSupervisor.start_child(
        Acari.TunsSup,
        {Acari.TunSup, %{sslinks: [%{name: "Link_A"}, %{name: "Link_B"}]}}
      )

    {:ok, state}
  end
end
