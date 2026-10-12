defmodule Streamix.Repo.Migrations.AddImdbIdIndexToMovies do
  use Ecto.Migration

  # Torrent ingestion maps a release's IMDb id to the TMDB id the catalog
  # already knows (Streamix.Torrent.Sync), once per listing page — YTS alone
  # walks ~1,500 pages a night. Without this index every lookup is a
  # sequential scan of movies. Built concurrently so writes are not blocked.
  @disable_ddl_transaction true

  def change do
    create index(:movies, [:imdb_id],
             name: :movies_imdb_id_idx,
             where: "imdb_id IS NOT NULL",
             concurrently: true
           )
  end
end
