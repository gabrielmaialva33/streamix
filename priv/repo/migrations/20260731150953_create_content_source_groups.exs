defmodule Streamix.Repo.Migrations.CreateContentSourceGroups do
  use Ecto.Migration

  def change do
    create table(:content_source_groups) do
      add :content_type, :string, null: false
      add :canonical_key, :string, null: false
      add :canonical_title, :string
      add :canonical_year, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:content_source_groups, [:content_type, :canonical_key])

    create constraint(:content_source_groups, :content_source_groups_valid_type,
             check: "content_type IN ('live_channel', 'movie', 'series', 'episode')"
           )

    alter table(:catalog_items) do
      add :source_group_id,
          references(:content_source_groups)

      add :source_match_method, :string
      add :source_match_confidence, :smallint
      add :source_verified_at, :utc_datetime
    end

    create index(:catalog_items, [:source_group_id])

    create constraint(:catalog_items, :catalog_items_source_confidence_range,
             check: "source_match_confidence IS NULL OR source_match_confidence BETWEEN 0 AND 100"
           )

    create constraint(:catalog_items, :catalog_items_source_match_method,
             check:
               "source_match_method IS NULL OR source_match_method IN ('tmdb', 'imdb', 'anilist', 'tomato', 'title_year', 'manual')"
           )

    create constraint(:catalog_items, :catalog_items_source_link_complete,
             check: """
             (source_group_id IS NULL AND source_match_method IS NULL AND source_match_confidence IS NULL AND source_verified_at IS NULL)
             OR
             (source_group_id IS NOT NULL AND source_match_method IS NOT NULL AND source_match_confidence IS NOT NULL)
             """
           )
  end
end
