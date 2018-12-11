defmodule AcariServer.HsSup do
  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    IO.puts("HS SUP")
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
