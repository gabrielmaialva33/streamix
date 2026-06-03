defmodule Streamix.Iptv.TorrentProvider do
  @moduledoc """
  System provider that aggregates content from torrent indexer sources
  (YTS, EZTV, GratisTorrent, ComandoTorrent, …).

  Identified by `is_system: true`, `visibility: :global`,
  `provider_type: :torrent`. There is at most one torrent provider per
  installation — individual sources live behind it via the
  `Streamix.Torrent.Source` behaviour rather than as separate
  Provider rows. This keeps the catalog UI uncluttered (a movie is
  "from torrents", not "from YTS-but-also-GratisTorrent") and lets
  TorrentStream rows stay deduped on info_hash regardless of which
  source surfaced them first.
  """

  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  import Ecto.Query

  require Logger

  @provider_name "Torrent Aggregator"
  @provider_url "torrent://aggregator"

  @doc """
  Returns true when the torrent feature is enabled in config.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Runtime configuration. Set in `config/runtime.exs`.

      config :streamix, :torrent_provider,
        enabled: System.get_env("TORRENT_ENABLED") == "true"
  """
  def config do
    Application.get_env(:streamix, :torrent_provider, enabled: false)
  end

  @doc """
  Fetches the torrent provider row, or `nil` when absent.
  """
  def get do
    Provider
    |> where(is_system: true, visibility: :global, provider_type: :torrent)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.one()
  end

  @doc """
  Idempotent bootstrap. Creates the row on first call, no-ops on
  subsequent ones. Mirrors `GIndexProvider.ensure_exists!/0`.
  """
  def ensure_exists! do
    if enabled?() do
      attrs = %{
        name: @provider_name,
        url: @provider_url,
        provider_type: :torrent,
        is_system: true,
        visibility: :global,
        is_active: true
      }

      case get() do
        nil ->
          Logger.info("[Torrent] Creating torrent aggregator provider...")
          create_provider(attrs)

        provider ->
          {:ok, provider}
      end
    else
      {:ok, :disabled}
    end
  end

  defp create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, provider} ->
        Logger.info("[Torrent] Provider created with ID #{provider.id}")

      {:error, changeset} ->
        Logger.error("[Torrent] Failed to create provider: #{inspect(changeset.errors)}")
    end)
  end
end
