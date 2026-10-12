defmodule Streamix.Repo.Migrations.AddReleaseFlagsToTorrentStreams do
  use Ecto.Migration

  # Quality warnings parsed from BR release titles: "unofficial_dub" (fan
  # dub / "Dublado Não Oficial") and "cam" (camera or telesync capture).
  # Flagged releases stay playable but rank behind clean ones.
  #
  # A constant default is a metadata-only change on PostgreSQL 11+, so the
  # column is added without rewriting torrent_streams.
  def change do
    alter table(:torrent_streams) do
      add :release_flags, {:array, :string}, null: false, default: []
    end
  end
end
