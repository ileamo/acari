defmodule Acari do
  defdelegate start_tun(name), to: Acari.TunSup
  defdelegate stop_tun(name), to: Acari.TunSup
end
