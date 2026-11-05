defmodule Streamix.Workers.SyncDueEpgWorker do
  @moduledoc """
  Keeps every active Xtream provider's TV guide fresh.

  Guide syncs used to start only when someone opened the live channels page
  filtered to that provider. The default "all" view only refreshes the global
  provider, so another provider's guide ran out after a couple of days and its
  channels showed no programs. This cron enqueues `SyncEpgWorker` for each
  provider whose guide is older than its interval; that worker is unique per
  provider for five minutes, so a page visit at the same moment adds nothing.
  """

  use Oban.Worker, queue: :sync, max_attempts: 1

  alias Streamix.{Guide, Providers}

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    due =
      [Providers.get_global_provider() | Providers.list_personal_xtream_providers()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(&1.is_active and Guide.epg_due?(&1)))

    Enum.each(due, &Guide.async_sync_epg/1)

    if due != [] do
      Logger.info("[EPG] enqueued guide sync for #{length(due)} provider(s)")
    end

    :ok
  end
end
