defmodule Acari.LinkSupervisor do
  # Automatically defines child_spec/1
  use Supervisor
  alias Acari.Link

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {Link, %{name: "Link_M1"}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
