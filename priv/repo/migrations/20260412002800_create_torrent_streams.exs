defmodule Streamix.Repo.Migrations.CreateTorrentStreams do
  use Ecto.Migration

  def change do
    create table(:torrent_streams) do
      # SHA-1 hex (40 chars). Unique across the whole table — same magnet
      # surfaces from multiple sources (YTS + ComandoTorrent + …) but the
      # info_hash collapses them onto a single torrent_streams row, with
      # source_slug noting where we first saw it.
      add :info_hash, :string, size: 40, null: false
      add :magnet_uri, :text, null: false

      # Release attributes parsed from the source listing or filename.
      add :quality, :string
      add :codec, :string
      add :audio_track, :string
      add :container, :string
      add :size_bytes, :bigint

      # Health snapshot. seeders is the working metric; refreshed by
      # RefreshSeedersWorker and used for "best torrent" ordering.
      add :seeders, :integer, default: 0, null: false
      add :leechers, :integer, default: 0, null: false
      add :seeders_updated_at, :utc_datetime

      add :source_slug, :string, null: false

      add :movie_id, references(:movies, on_delete: :delete_all)
      add :episode_id, references(:episodes, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:torrent_streams, [:info_hash])
    create index(:torrent_streams, [:movie_id])
    create index(:torrent_streams, [:episode_id])

    # The "pick best torrent for movie" hot path orders by seeders desc.
    # Partial index keeps it cheap when most rows belong to dead torrents.
    create index(:torrent_streams, [:movie_id, :seeders],
             where: "seeders > 0",
             name: :torrent_streams_movie_id_seeders_index
           )

    create constraint(:torrent_streams, :info_hash_format, check: "info_hash ~ '^[0-9a-f]{40}$'")

    create constraint(:torrent_streams, :movie_or_episode,
             check: "((movie_id IS NOT NULL)::int + (episode_id IS NOT NULL)::int) = 1"
           )
  end
end
