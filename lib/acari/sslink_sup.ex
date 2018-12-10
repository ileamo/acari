defmodule Acari.SSLinkSup do
  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  defdelegate start_link_worker(sup, spec), to: DynamicSupervisor, as: :start_child

  @impl true
  def init(_arg) do
    IO.puts("START SSLINK SUP")
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
