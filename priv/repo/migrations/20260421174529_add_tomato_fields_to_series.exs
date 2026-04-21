defmodule Streamix.Repo.Migrations.AddTomatoFieldsToSeries do
  use Ecto.Migration

  # TomatoAnimes is the first anime-catalog-specific enrichment source we
  # call (ahead of AniList and TMDB) because its `name` field is usually
  # in romaji with a Portuguese plot + tags attached — exactly the shape
  # that matches the brazilian gindex folder names best. `tomato_id`
  # lives in its own column for the same reason `anilist_id` does:
  # downstream code that assumes `tmdb_id` corresponds to a real TMDB
  # resource mustn't blow up on cross-source rows.
  def change do
    alter table(:series) do
      add :tomato_id, :integer
      add :dub_available, :boolean, default: false, null: false
    end

    create index(:series, [:tomato_id],
             where: "tomato_id IS NOT NULL",
             name: :series_tomato_id_idx
           )
  end
end
