defmodule Streamix.Workers.CleanupWatchPartyRoomsWorker do
  @moduledoc """
  Ends abandoned Watch Party rooms and purges old ended-room metadata.

  Active room processes persist their heartbeat at least every 15 seconds. A
  thirty-minute cutoff therefore leaves a large safety margin for deploys and
  temporary database outages while still recovering rooms whose process died.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :timer.minutes(10), fields: [:worker], states: :incomplete]

  alias Streamix.WatchParty

  require Logger

  @active_timeout_seconds 30 * 60
  @ended_retention_seconds 90 * 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    active_cutoff = DateTime.add(now, -@active_timeout_seconds, :second)
    ended_cutoff = DateTime.add(now, -@ended_retention_seconds, :second)

    expired = WatchParty.expire_inactive_rooms(active_cutoff)
    purged = WatchParty.purge_ended_rooms(ended_cutoff)

    if expired > 0 or purged > 0 do
      Logger.info("[WatchPartyCleanup] expired=#{expired} purged=#{purged}")
    end

    :ok
  end
end
