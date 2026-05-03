defmodule Streamix.Workers.SyncEpgWorker do
  @moduledoc """
  Background worker that syncs the full EPG catalog for a provider.

  Issues exactly **one** HTTP request per run — `/xmltv.php` returns a
  complete XMLTV document covering every channel. This is the same
  endpoint XCIPTV, TiviMate, IPTVSmarters and IBOPlayer hit, so the
  provider's anti-scraper WAF can't tell us apart from a normal client.

  Until 2026-05-03 this worker iterated 776 channels and called
  `get_short_epg` once per channel. That triggered the Choki provider's
  WAF and got the IPTV account suspended. Switched to XMLTV bulk fetch
  to mirror real-client behaviour.

  ## Error handling

  * Two attempts max — if the provider says no, don't keep hammering
  * Snoozes 5 min on transient errors (timeout, transport)
  * Discards on permanent errors (auth failure, account suspended)
  * Unique within a 5-minute window per provider
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 2,
    unique: [period: 300, keys: [:provider_id]]

  alias Streamix.Iptv
  alias Streamix.Iptv.{EpgSync, Provider}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}, attempt: attempt}) do
    case Iptv.get_provider(provider_id) do
      nil ->
        {:error, :provider_not_found}

      provider ->
        run(provider, attempt)
    end
  end

  defp run(%Provider{} = provider, attempt) do
    Logger.info(
      "[SyncEpgWorker] Starting XMLTV-based EPG sync for provider #{provider.id} " <>
        "(attempt #{attempt})"
    )

    case EpgSync.sync_all_epg(provider) do
      {:ok, %{channels: ch, programs: pr} = stats} ->
        broadcast(provider, %{synced: ch, programs: pr, failed: 0})
        Logger.info("[SyncEpgWorker] Done: #{inspect(stats)}")
        :ok

      {:error, reason} when is_atom(reason) ->
        # E.g. :empty_xmltv, :provider_not_found, :invalid_xmltv —
        # not transient. Don't retry.
        broadcast(provider, %{synced: 0, programs: 0, failed: 1, error: reason})
        {:discard, reason}

      {:error, {:transport_error, _}} = err ->
        broadcast(provider, %{synced: 0, programs: 0, failed: 1, error: :transport_error})
        snooze(err)

      {:error, {:circuit_open, _}} = err ->
        broadcast(provider, %{synced: 0, programs: 0, failed: 1, error: :circuit_open})
        snooze(err)

      {:error, {:http_error, status}} when status in 500..599 ->
        broadcast(provider, %{synced: 0, programs: 0, failed: 1, error: {:http_error, status}})
        snooze({:http_error, status})

      {:error, reason} ->
        broadcast(provider, %{synced: 0, programs: 0, failed: 1, error: reason})
        {:error, reason}
    end
  end

  defp snooze(reason) do
    Logger.warning("[SyncEpgWorker] Transient failure (#{inspect(reason)}), snoozing 5 min")
    {:snooze, 300}
  end

  defp broadcast(provider, results) do
    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "provider:#{provider.id}",
      {:epg_sync_complete, :ok, results}
    )
  end

  @doc """
  Enqueues an EPG sync job for the given provider.
  """
  def enqueue(%Provider{} = provider), do: enqueue(provider.id)

  def enqueue(provider_id) when is_integer(provider_id) or is_binary(provider_id) do
    %{provider_id: provider_id}
    |> new()
    |> Oban.insert()
  end
end
