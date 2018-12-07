defmodule Acari.LinkManager do
  require Logger
  use GenServer
  alias Acari.LinkSupervisor
  alias Acari.Link

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    Logger.debug("START LINK MANAGER")
    LinkSupervisor.start_link_worker(LinkSupervisor, {Link, %{}})
    LinkSupervisor.start_link_worker(LinkSupervisor, {Link, %{}})
    {:ok, state}
  end
end
