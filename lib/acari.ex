defmodule Acari do
  defdelegate start_tun(name), to: Acari.TunSup
  defdelegate stop_tun(name), to: Acari.TunSup
  defdelegate add_link(tun_name, link_name, connector), to: Acari.TunMan
  defdelegate del_link(tun_name, link_name), to: Acari.TunMan
  defdelegate get_all_links(tun_name), to: Acari.TunMan
end
