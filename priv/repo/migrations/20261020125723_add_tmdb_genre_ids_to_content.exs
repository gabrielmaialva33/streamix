defmodule Streamix.Repo.Migrations.AddTmdbGenreIdsToContent do
  use Ecto.Migration

  def change do
    create index(:series, [:tmdb_id], where: "tmdb_id IS NOT NULL")

    for content <- [:movies, :series] do
      alter table(content) do
        add :tmdb_genre_ids, {:array, :integer}
      end

      create index(content, [:tmdb_id],
               where: "tmdb_genre_ids IS NULL AND tmdb_id IS NOT NULL",
               name: :"#{content}_pending_tmdb_genres_idx"
             )
    end
  end
end
