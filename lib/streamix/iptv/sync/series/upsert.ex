defmodule Streamix.Iptv.Sync.Series.Upsert do
  @moduledoc """
  Series list synchronization, category association rebuilds, and orphan cleanup.
  """

  alias Streamix.Iptv.{Provider, Series, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Iptv.Sync.Normalizers.Series, as: SeriesNormalizer
  alias Streamix.Repo

  require Logger

  @sync_opts [
    schema: Series,
    stream_id_field: :series_id,
    content_type: "series"
  ]

  @doc """
  Syncs series without details for a provider.
  """
  def sync_series(%Provider{} = provider) do
    Logger.info("Syncing series for provider #{provider.id}")

    case XtreamClient.get_series(provider.url, provider.username, provider.password,
           provider_id: provider.id,
           allow_private_network: provider.is_system
         ) do
      {:ok, series_list} ->
        sync_series_list(provider, series_list)

      {:error, reason} ->
        {:error, {:series_sync_failed, reason}}
    end
  end

  defp sync_series_list(provider, series_list) do
    category_lookup = Helpers.build_category_lookup(provider.id, "series")
    now = DateTime.utc_now(:second)

    upsert_opts =
      @sync_opts
      |> Keyword.put(:attrs_fn, &SeriesNormalizer.attrs/3)
      |> Keyword.put(:category_fn, &build_category_assocs/3)
      |> Keyword.put(:type, :series)
      |> Keyword.put(:provider, provider)

    {count, all_series_ids} =
      Helpers.upsert_content_batched(
        series_list,
        provider.id,
        category_lookup,
        now,
        upsert_opts
      )

    Helpers.sync_genres_and_credits(
      series_list,
      provider.id,
      Series,
      "series_genres",
      "series_id",
      credits_table: "series_credits",
      stream_id_key: "series_id"
    )

    deleted_count =
      Helpers.delete_orphaned_content(provider.id, all_series_ids, @sync_opts)

    now_utc = DateTime.utc_now(:second)

    provider
    |> Provider.sync_changeset(%{series_count: count, series_synced_at: now_utc})
    |> Repo.update()

    Logger.info("Synced #{count} series, removed #{deleted_count} orphaned")
    {:ok, count}
  end

  defp build_category_assocs(series_list, returned, category_lookup) do
    Helpers.build_category_assocs(series_list, returned, category_lookup)
  end
end
