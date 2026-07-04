defmodule Streamix.Repo.Migrations.AddMoviesTmdbIdIndex do
  use Ecto.Migration

  def change do
    create index(:movies, [:tmdb_id],
             name: :movies_tmdb_id_idx,
             where: "tmdb_id IS NOT NULL AND tmdb_id <> ''"
           )
  end
end
