defmodule Streamix.Repo.Migrations.AddTmdbKeywordsToContent do
  use Ecto.Migration

  # TMDB keywords are the community-curated tags ("time travel", "heist",
  # "based on novel") that the 24 canonical genres are too coarse to express.
  # The ids live on each copy like `tmdb_genre_ids`: NULL means "not fetched
  # yet", an empty array means "TMDB answered with none".
  def change do
    create table(:tmdb_keywords, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    for content <- [:movies, :series] do
      alter table(content) do
        add :tmdb_keyword_ids, {:array, :integer}
      end

      create index(content, [:tmdb_id],
               where: "tmdb_keyword_ids IS NULL AND tmdb_id IS NOT NULL",
               name: :"#{content}_pending_tmdb_keywords_idx"
             )

      create index(content, [:tmdb_keyword_ids], using: :gin)
    end
  end
end
