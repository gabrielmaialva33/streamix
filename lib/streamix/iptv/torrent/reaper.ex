defmodule Streamix.Iptv.Torrent.Reaper do
  @moduledoc """
  Periodic sweeper that drops rqbit torrents Streamix has lost track
  of.

  Runs every 5 minutes. For each torrent rqbit reports via
  `Client.list/0`, we look it up in `StreamRegistry`. If no
  `StreamSession` claims it, we issue `Client.remove/1` to free the
  on-disk pieces. This catches:

    * left-over torrents from a previous BEAM run (no session ever
      registered);
    * sessions that crashed without running their `terminate/2`
      callback;
    * torrents added out-of-band (e.g. an operator running
      `curl rqbit/torrents` for diagnostics).

  Defensive by design — never touches a torrent that has a live
  session even if the rqbit-reported state suggests it could be
  evicted. The session is the source of truth.
  """

  use GenServer

  require Logger

  alias Streamix.Iptv.Torrent.{Client, StreamSession}

  @registry Streamix.Iptv.Torrent.StreamRegistry

  @default_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Synchronously run one sweep. Used by tests.
  """
  def sweep_now(name \\ __MODULE__) do
    GenServer.call(name, :sweep_now, :timer.seconds(30))
  end

  # ---- GenServer ----

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, do_sweep(), state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp do_sweep do
    case Client.list() do
      {:ok, torrents} ->
        Enum.each(torrents, &maybe_reap/1)
        :ok

      {:error, reason} ->
        Logger.debug("[Torrent.Reaper] list failed: #{inspect(reason)}")
        :error
    end
  end

  defp maybe_reap(%{info_hash: hash} = torrent) when is_binary(hash) do
    info_hash = String.downcase(hash)

    # Two-phase check: a viewer can register a brand-new session in the
    # narrow window between `Client.list/0` and the actual Client.remove
    # call. We `registered?/1` again right before removing so a session
    # that just woke up isn't yanked out from under its first viewer.
    if registered?(info_hash) do
      :ok
    else
      reap_if_still_unregistered(info_hash, torrent)
    end
  end

  defp maybe_reap(_), do: :ok

  defp reap_if_still_unregistered(info_hash, torrent) do
    if registered?(info_hash) do
      Logger.debug("[Torrent.Reaper] skipping #{info_hash} — session registered mid-sweep")

      :ok
    else
      Logger.info("[Torrent.Reaper] reaping orphaned torrent #{info_hash}")

      case Client.remove(info_hash) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Torrent.Reaper] failed to remove #{info_hash}: #{inspect(reason)}")
      end

      # If for some reason the id was preferred and removal still
      # left the torrent in place, try the numeric id too.
      case torrent do
        %{id: id} when is_integer(id) -> Client.remove(id)
        _ -> :ok
      end
    end
  end

  defp registered?(info_hash) do
    Registry.lookup(@registry, info_hash) != [] or
      StreamSession.whereis(info_hash) != nil
  end
end
