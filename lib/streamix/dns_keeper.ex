defmodule Streamix.DnsKeeper do
  @moduledoc """
  Re-pins our preferred public DNS resolvers (1.1.1.1, 1.0.0.1, 8.8.8.8)
  on top of whatever Erlang's `inet_db` derived from `/etc/resolv.conf`.

  Why this exists: inside the Docker bridge network the only resolver in
  `/etc/resolv.conf` is the embedded Docker resolver at 127.0.0.11.
  That resolver is the proximate cause of the transient `:nxdomain`
  bursts we see during GIndex sync — when it flaps, every connect via
  Mint/Finch fails the same way. Adding 1.1.1.1/8.8.8.8 as additional
  Erlang nameservers gives `inet_res` a healthy fallback per query.

  Why a GenServer instead of just calling `:inet_db.add_ns/1` once at
  boot: `inet_db` periodically re-reads `/etc/resolv.conf` and resets
  the nameservers list to whatever it finds there, dropping anything
  added in code. This process re-applies the public NS entries on a
  short interval so the additions stick.
  """

  use GenServer
  require Logger

  @nameservers [{1, 1, 1, 1}, {1, 0, 0, 1}, {8, 8, 8, 8}]
  @refresh_interval :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    reapply()
    schedule_refresh()
    {:ok, nil}
  end

  @impl true
  def handle_info(:refresh, state) do
    reapply()
    schedule_refresh()
    {:noreply, state}
  end

  defp reapply do
    current =
      :inet_db.res_option(:nameservers)
      |> Enum.map(fn {ip, _port} -> ip end)

    for ns <- @nameservers, ns not in current do
      :inet_db.add_ns(ns)
    end
  rescue
    error ->
      Logger.warning("[DnsKeeper] failed to reapply nameservers: #{inspect(error)}")
      :ok
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)
end
